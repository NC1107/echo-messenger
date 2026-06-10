//! Per-event-kind schema validation for voice-lounge canvas events.
//!
//! Every validator is a pure function: it inspects a `serde_json::Value`
//! payload and returns either `Ok(())` (payload passes the kind's schema)
//! or `Err(ValidationError)` carrying a stable, log-greppable code.
//!
//! The validators here are the *floor* of safety — paired with the existing
//! byte-size cap (`MAX_CANVAS_PAYLOAD_BYTES`) and the event-kind allowlist,
//! they reject pathological geometry (`NaN`, `Infinity`, 1e30, negative
//! widths, point arrays of length 1_000_000 within the byte budget) before
//! it reaches persistence or relay.
//!
//! Error codes follow `canvas.validation.<kind>.<field>.<reason>` so future
//! log analysis stays sane (see PR B of the canvas redesign plan).

use serde_json::Value;

// ---------------------------------------------------------------------------
// Public surface
// ---------------------------------------------------------------------------

/// Bound for coordinates in the 100 000 × 100 000 canvas-world surface.
/// `kCanvasWidth = 100_000` on the client; we accept a small slack window
/// past that for legacy 0..1 migration helpers + clamps.
pub const CANVAS_COORD_MIN: f64 = -1_000.0;
pub const CANVAS_COORD_MAX: f64 = 110_000.0;
/// Hard limit on the canvas surface itself. Width/height for image entities
/// cannot exceed this — anything larger is almost certainly garbage.
pub const CANVAS_SURFACE_MAX: f64 = 100_000.0;

/// Caps for stroke point arrays.
pub const MAX_STROKE_POINTS: usize = 5_000;
pub const MAX_STROKE_PARTIAL_POINTS: usize = 200;

/// Stroke width sanity bound. 200 px is well beyond any practical brush.
pub const MAX_STROKE_WIDTH: f64 = 200.0;

/// Lenient bound for legacy screen-share CSS-pixel coords. Real viewports
/// are 0..3840, but we leave a generous fudge for unusual DPI scaling.
pub const LEGACY_SCREENSHARE_MIN: f64 = -10_000.0;
pub const LEGACY_SCREENSHARE_MAX: f64 = 10_000.0;

/// Max length of the `window_id` string in screenshare events.
pub const MAX_WINDOW_ID_LEN: usize = 64;

/// Tools mirrored from the Dart `CanvasTool` enum.
pub const VALID_TOOLS: &[&str] = &[
    "freehand",
    "highlighter",
    "eraser",
    "rectangle",
    "ellipse",
    "arrow",
    "line",
    "text",
];

/// Stable, log-greppable code for a rejected payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidationError {
    pub code: String,
}

impl ValidationError {
    fn new(code: impl Into<String>) -> Self {
        Self { code: code.into() }
    }
}

impl std::fmt::Display for ValidationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.code)
    }
}

/// Validate a canvas event payload against the schema for its `kind`.
///
/// Unknown kinds are not rejected here — the caller already enforces the
/// kind allowlist. This function returns `Ok(())` for any kind it does not
/// have a validator for so future kinds aren't accidentally blocked when
/// added to the allowlist before a schema lands.
pub fn validate(kind: &str, payload: &Value) -> Result<(), ValidationError> {
    match kind {
        "stroke" => validate_stroke(payload),
        "stroke_partial" => validate_stroke_partial(payload),
        "clear" => validate_clear(payload),
        "image_add" => validate_image_add(payload),
        "image_move" => validate_image_move(payload),
        "image_remove" => validate_image_remove(payload),
        "avatar_move" => validate_avatar_move(payload),
        "screenshare_move" => validate_screenshare_move(payload),
        _ => Ok(()),
    }
}

// ---------------------------------------------------------------------------
// Per-field helpers (kept tiny so each validator stays inside the cognitive
// complexity budget).
// ---------------------------------------------------------------------------

fn finite_f64(payload: &Value, field: &str) -> Result<f64, ValidationError> {
    let v = payload.get(field).and_then(Value::as_f64).ok_or_else(|| {
        ValidationError::new(format!(
            "canvas.validation.field.{field}.missing_or_not_number"
        ))
    })?;
    if !v.is_finite() {
        return Err(ValidationError::new(format!(
            "canvas.validation.field.{field}.not_finite"
        )));
    }
    Ok(v)
}

fn finite_f64_in(payload: &Value, field: &str, min: f64, max: f64) -> Result<f64, ValidationError> {
    let v = finite_f64(payload, field)?;
    if v < min || v > max {
        return Err(ValidationError::new(format!(
            "canvas.validation.field.{field}.out_of_range"
        )));
    }
    Ok(v)
}

fn canvas_coord(payload: &Value, field: &str) -> Result<f64, ValidationError> {
    finite_f64_in(payload, field, CANVAS_COORD_MIN, CANVAS_COORD_MAX)
}

fn is_uuid_shaped(s: &str) -> bool {
    if s.len() != 36 {
        return false;
    }
    let bytes = s.as_bytes();
    for (i, b) in bytes.iter().enumerate() {
        let is_dash = matches!(i, 8 | 13 | 18 | 23);
        if is_dash {
            if *b != b'-' {
                return false;
            }
        } else if !b.is_ascii_hexdigit() {
            return false;
        }
    }
    true
}

fn require_uuid(payload: &Value, field: &str) -> Result<(), ValidationError> {
    let s = payload
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| ValidationError::new(format!("canvas.validation.field.{field}.missing")))?;
    if !is_uuid_shaped(s) {
        return Err(ValidationError::new(format!(
            "canvas.validation.field.{field}.not_uuid"
        )));
    }
    Ok(())
}

fn is_hex_color(s: &str) -> bool {
    let bytes = s.as_bytes();
    if bytes.first() != Some(&b'#') {
        return false;
    }
    if bytes.len() != 7 && bytes.len() != 9 {
        return false;
    }
    bytes[1..].iter().all(u8::is_ascii_hexdigit)
}

// ---------------------------------------------------------------------------
// stroke / stroke_partial
// ---------------------------------------------------------------------------

fn validate_point(point: &Value, idx: usize) -> Result<(), ValidationError> {
    let x = point.get("x").and_then(Value::as_f64).ok_or_else(|| {
        ValidationError::new(format!("canvas.validation.stroke.points[{idx}].x.missing"))
    })?;
    let y = point.get("y").and_then(Value::as_f64).ok_or_else(|| {
        ValidationError::new(format!("canvas.validation.stroke.points[{idx}].y.missing"))
    })?;
    if !x.is_finite() || !y.is_finite() {
        return Err(ValidationError::new(format!(
            "canvas.validation.stroke.points[{idx}].not_finite"
        )));
    }
    if !(CANVAS_COORD_MIN..=CANVAS_COORD_MAX).contains(&x)
        || !(CANVAS_COORD_MIN..=CANVAS_COORD_MAX).contains(&y)
    {
        return Err(ValidationError::new(format!(
            "canvas.validation.stroke.points[{idx}].out_of_range"
        )));
    }
    Ok(())
}

fn validate_points_array(payload: &Value, max_len: usize) -> Result<(), ValidationError> {
    let points = payload
        .get("points")
        .and_then(Value::as_array)
        .ok_or_else(|| ValidationError::new("canvas.validation.stroke.points.missing"))?;
    if points.is_empty() {
        return Err(ValidationError::new(
            "canvas.validation.stroke.points.empty",
        ));
    }
    if points.len() > max_len {
        return Err(ValidationError::new(
            "canvas.validation.stroke.points.too_many",
        ));
    }
    for (i, p) in points.iter().enumerate() {
        validate_point(p, i)?;
    }
    Ok(())
}

fn validate_optional_stroke_meta(payload: &Value) -> Result<(), ValidationError> {
    if let Some(color) = payload.get("color") {
        let s = color
            .as_str()
            .ok_or_else(|| ValidationError::new("canvas.validation.stroke.color.not_string"))?;
        if !is_hex_color(s) {
            return Err(ValidationError::new(
                "canvas.validation.stroke.color.not_hex",
            ));
        }
    }
    if let Some(width) = payload.get("width") {
        let w = width
            .as_f64()
            .ok_or_else(|| ValidationError::new("canvas.validation.stroke.width.not_number"))?;
        if !w.is_finite() || w <= 0.0 || w > MAX_STROKE_WIDTH {
            return Err(ValidationError::new(
                "canvas.validation.stroke.width.out_of_range",
            ));
        }
    }
    if let Some(tool) = payload.get("tool") {
        let s = tool
            .as_str()
            .ok_or_else(|| ValidationError::new("canvas.validation.stroke.tool.not_string"))?;
        if !VALID_TOOLS.contains(&s) {
            return Err(ValidationError::new(
                "canvas.validation.stroke.tool.unknown",
            ));
        }
    }
    Ok(())
}

fn validate_stroke(payload: &Value) -> Result<(), ValidationError> {
    validate_points_array(payload, MAX_STROKE_POINTS)?;
    validate_optional_stroke_meta(payload)
}

fn validate_stroke_partial(payload: &Value) -> Result<(), ValidationError> {
    // stroke_partial is just a live-preview frame; per-point bounds still
    // apply, but optional meta fields are ignored.
    validate_points_array(payload, MAX_STROKE_PARTIAL_POINTS)
}

// ---------------------------------------------------------------------------
// clear
// ---------------------------------------------------------------------------

fn validate_clear(payload: &Value) -> Result<(), ValidationError> {
    // Empty payload (object or null) is fine.
    match payload {
        Value::Null => Ok(()),
        Value::Object(map) if map.is_empty() => Ok(()),
        Value::Object(map) => {
            // Only `scope` is allowed, and its value is one of two literals.
            for k in map.keys() {
                if k != "scope" {
                    return Err(ValidationError::new(format!(
                        "canvas.validation.clear.{k}.unknown_field"
                    )));
                }
            }
            if let Some(scope) = map.get("scope") {
                let s = scope.as_str().ok_or_else(|| {
                    ValidationError::new("canvas.validation.clear.scope.not_string")
                })?;
                if s != "all" && s != "mine" {
                    return Err(ValidationError::new(
                        "canvas.validation.clear.scope.unknown_value",
                    ));
                }
            }
            Ok(())
        }
        _ => Err(ValidationError::new("canvas.validation.clear.not_object")),
    }
}

// ---------------------------------------------------------------------------
// image_add / image_move / image_remove
// ---------------------------------------------------------------------------

fn validate_image_dims(payload: &Value) -> Result<(), ValidationError> {
    let w = finite_f64(payload, "width")?;
    let h = finite_f64(payload, "height")?;
    if w <= 0.0 || w > CANVAS_SURFACE_MAX {
        return Err(ValidationError::new(
            "canvas.validation.image.width.out_of_range",
        ));
    }
    if h <= 0.0 || h > CANVAS_SURFACE_MAX {
        return Err(ValidationError::new(
            "canvas.validation.image.height.out_of_range",
        ));
    }
    Ok(())
}

fn validate_image_url(payload: &Value) -> Result<(), ValidationError> {
    let url = payload
        .get("url")
        .and_then(Value::as_str)
        .ok_or_else(|| ValidationError::new("canvas.validation.image_add.url.missing"))?;
    if !url.starts_with("/api/media/") {
        return Err(ValidationError::new(
            "canvas.validation.image_add.url.not_relative",
        ));
    }
    Ok(())
}

fn validate_image_add(payload: &Value) -> Result<(), ValidationError> {
    require_uuid(payload, "id")?;
    validate_image_url(payload)?;
    canvas_coord(payload, "x")?;
    canvas_coord(payload, "y")?;
    validate_image_dims(payload)
}

/// Extract the media UUID referenced by an `image_add` payload's `url`.
///
/// Production media URLs are `/api/media/<uuid>` (optionally suffixed with
/// `/thumb`). The first path segment after `/api/media/` must parse as a
/// UUID; any extension or sub-path is rejected so the ownership check in the
/// async handler always runs against a canonical id.
///
/// Returns `None` when the URL is missing, not the expected shape, or the id
/// segment is not a UUID — the caller treats that as "reject".
pub fn media_id_from_image_add(payload: &Value) -> Option<uuid::Uuid> {
    const PREFIX: &str = "/api/media/";
    let url = payload.get("url").and_then(Value::as_str)?;
    let rest = url.strip_prefix(PREFIX)?;
    // Take only the first path segment; drop a trailing `/thumb` etc.
    let segment = rest.split('/').next()?;
    uuid::Uuid::parse_str(segment).ok()
}

fn validate_image_move(payload: &Value) -> Result<(), ValidationError> {
    require_uuid(payload, "id")?;
    canvas_coord(payload, "x")?;
    canvas_coord(payload, "y")?;
    let has_w = payload.get("width").is_some();
    let has_h = payload.get("height").is_some();
    match (has_w, has_h) {
        (false, false) => Ok(()),
        (true, true) => validate_image_dims(payload),
        _ => Err(ValidationError::new(
            "canvas.validation.image_move.dims.partial",
        )),
    }
}

fn validate_image_remove(payload: &Value) -> Result<(), ValidationError> {
    require_uuid(payload, "id")
}

// ---------------------------------------------------------------------------
// avatar_move
// ---------------------------------------------------------------------------

fn validate_avatar_move(payload: &Value) -> Result<(), ValidationError> {
    require_uuid(payload, "user_id")?;
    canvas_coord(payload, "x")?;
    canvas_coord(payload, "y")?;
    Ok(())
}

// ---------------------------------------------------------------------------
// screenshare_move (dual format during the coord_v=1 → coord_v=2 transition)
// ---------------------------------------------------------------------------

fn validate_window_id(payload: &Value) -> Result<(), ValidationError> {
    let s = payload
        .get("window_id")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            ValidationError::new("canvas.validation.screenshare_move.window_id.missing")
        })?;
    if s.is_empty() {
        return Err(ValidationError::new(
            "canvas.validation.screenshare_move.window_id.empty",
        ));
    }
    if s.len() > MAX_WINDOW_ID_LEN {
        return Err(ValidationError::new(
            "canvas.validation.screenshare_move.window_id.too_long",
        ));
    }
    Ok(())
}

fn validate_screenshare_v2(payload: &Value) -> Result<(), ValidationError> {
    for field in ["x_norm", "y_norm", "w_norm", "h_norm"] {
        finite_f64_in(payload, field, 0.0, 1.0)?;
    }
    Ok(())
}

fn validate_screenshare_legacy(payload: &Value) -> Result<(), ValidationError> {
    for field in ["x", "y", "width", "height"] {
        finite_f64_in(
            payload,
            field,
            LEGACY_SCREENSHARE_MIN,
            LEGACY_SCREENSHARE_MAX,
        )?;
    }
    Ok(())
}

fn validate_screenshare_move(payload: &Value) -> Result<(), ValidationError> {
    validate_window_id(payload)?;
    let coord_v = payload.get("coord_v").and_then(Value::as_i64);
    match coord_v {
        None | Some(1) => validate_screenshare_legacy(payload),
        Some(2) => validate_screenshare_v2(payload),
        Some(_) => Err(ValidationError::new(
            "canvas.validation.screenshare_move.coord_v.unsupported",
        )),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn err_code(kind: &str, payload: Value) -> String {
        validate(kind, &payload).expect_err("should reject").code
    }

    // -- stroke ------------------------------------------------------------

    #[test]
    fn stroke_valid_payload_passes() {
        let payload = json!({
            "points": [{"x": 0.0, "y": 0.0}, {"x": 100.0, "y": 50.0}],
            "color": "#ff00aa",
            "width": 4.0,
            "tool": "freehand"
        });
        assert!(validate("stroke", &payload).is_ok());
    }

    #[test]
    fn stroke_rejects_non_numeric_x() {
        // `serde_json::json!` cannot encode NaN/Infinity (invalid JSON), so
        // simulate the on-the-wire equivalent: a non-number where x is
        // expected. The validator must still reject it.
        let payload = json!({"points": [{"x": "nope", "y": 0.0}]});
        assert!(err_code("stroke", payload).contains("missing"));
    }

    #[test]
    fn stroke_rejects_missing_y() {
        let payload = json!({"points": [{"x": 0.0}]});
        assert!(err_code("stroke", payload).contains("y.missing"));
    }

    #[test]
    fn stroke_rejects_out_of_range_x() {
        let payload = json!({"points": [{"x": 1.0e9, "y": 0.0}]});
        assert!(err_code("stroke", payload).contains("out_of_range"));
    }

    #[test]
    fn stroke_rejects_too_many_points() {
        let pts: Vec<_> = (0..6000).map(|_| json!({"x": 1.0, "y": 1.0})).collect();
        let payload = json!({"points": pts});
        assert!(err_code("stroke", payload).contains("too_many"));
    }

    #[test]
    fn stroke_rejects_empty_points() {
        let payload = json!({"points": []});
        assert!(err_code("stroke", payload).contains("empty"));
    }

    #[test]
    fn stroke_rejects_missing_points() {
        let payload = json!({});
        assert!(err_code("stroke", payload).contains("missing"));
    }

    #[test]
    fn stroke_rejects_bad_hex_color() {
        let payload = json!({"points": [{"x": 0.0, "y": 0.0}], "color": "red"});
        assert!(err_code("stroke", payload).contains("color.not_hex"));
    }

    #[test]
    fn stroke_accepts_rgba_hex() {
        let payload = json!({"points": [{"x": 0.0, "y": 0.0}], "color": "#ff00aaff"});
        assert!(validate("stroke", &payload).is_ok());
    }

    #[test]
    fn stroke_rejects_negative_width() {
        let payload = json!({"points": [{"x": 0.0, "y": 0.0}], "width": -1.0});
        assert!(err_code("stroke", payload).contains("width.out_of_range"));
    }

    #[test]
    fn stroke_rejects_huge_width() {
        let payload = json!({"points": [{"x": 0.0, "y": 0.0}], "width": 500.0});
        assert!(err_code("stroke", payload).contains("width.out_of_range"));
    }

    #[test]
    fn stroke_rejects_unknown_tool() {
        let payload = json!({"points": [{"x": 0.0, "y": 0.0}], "tool": "lightsaber"});
        assert!(err_code("stroke", payload).contains("tool.unknown"));
    }

    // -- stroke_partial ---------------------------------------------------

    #[test]
    fn stroke_partial_caps_at_200_points() {
        let pts: Vec<_> = (0..201).map(|_| json!({"x": 1.0, "y": 1.0})).collect();
        let payload = json!({"points": pts});
        assert!(err_code("stroke_partial", payload).contains("too_many"));
    }

    #[test]
    fn stroke_partial_ignores_optional_meta() {
        // 'tool: chainsaw' would fail validate_stroke but stroke_partial ignores it.
        let payload = json!({
            "points": [{"x": 0.0, "y": 0.0}],
            "tool": "chainsaw"
        });
        assert!(validate("stroke_partial", &payload).is_ok());
    }

    // -- clear -------------------------------------------------------------

    #[test]
    fn clear_accepts_empty_object() {
        assert!(validate("clear", &json!({})).is_ok());
    }

    #[test]
    fn clear_accepts_scope_all() {
        assert!(validate("clear", &json!({"scope": "all"})).is_ok());
    }

    #[test]
    fn clear_accepts_scope_mine() {
        assert!(validate("clear", &json!({"scope": "mine"})).is_ok());
    }

    #[test]
    fn clear_rejects_unknown_scope() {
        let payload = json!({"scope": "everything-please"});
        assert!(err_code("clear", payload).contains("scope.unknown_value"));
    }

    #[test]
    fn clear_rejects_unknown_field() {
        let payload = json!({"haha": "gotcha"});
        assert!(err_code("clear", payload).contains("unknown_field"));
    }

    // -- media_id_from_image_add ------------------------------------------

    #[test]
    fn media_id_parses_canonical_url() {
        let p = json!({"url": "/api/media/11111111-1111-1111-1111-111111111111"});
        assert_eq!(
            media_id_from_image_add(&p).unwrap().to_string(),
            "11111111-1111-1111-1111-111111111111"
        );
    }

    #[test]
    fn media_id_strips_thumb_suffix() {
        let p = json!({"url": "/api/media/22222222-2222-2222-2222-222222222222/thumb"});
        assert_eq!(
            media_id_from_image_add(&p).unwrap().to_string(),
            "22222222-2222-2222-2222-222222222222"
        );
    }

    #[test]
    fn media_id_rejects_non_uuid_segment() {
        let p = json!({"url": "/api/media/abc.png"});
        assert!(media_id_from_image_add(&p).is_none());
    }

    #[test]
    fn media_id_rejects_foreign_prefix() {
        let p = json!({"url": "https://evil.example.com/x.png"});
        assert!(media_id_from_image_add(&p).is_none());
    }

    #[test]
    fn media_id_rejects_missing_url() {
        assert!(media_id_from_image_add(&json!({})).is_none());
    }

    // -- image_add --------------------------------------------------------

    fn good_image_add() -> Value {
        json!({
            "id": "11111111-1111-1111-1111-111111111111",
            "url": "/api/media/abc.png",
            "x": 100.0,
            "y": 200.0,
            "width": 400.0,
            "height": 300.0
        })
    }

    #[test]
    fn image_add_valid_passes() {
        assert!(validate("image_add", &good_image_add()).is_ok());
    }

    #[test]
    fn image_add_rejects_non_uuid() {
        let mut p = good_image_add();
        p["id"] = json!("not-a-uuid");
        assert!(err_code("image_add", p).contains("id.not_uuid"));
    }

    #[test]
    fn image_add_rejects_absolute_url() {
        let mut p = good_image_add();
        p["url"] = json!("https://evil.example.com/x.png");
        assert!(err_code("image_add", p).contains("url.not_relative"));
    }

    #[test]
    fn image_add_rejects_negative_width() {
        let mut p = good_image_add();
        p["width"] = json!(-50.0);
        assert!(err_code("image_add", p).contains("width.out_of_range"));
    }

    #[test]
    fn image_add_rejects_huge_width() {
        let mut p = good_image_add();
        p["width"] = json!(1.0e9);
        assert!(err_code("image_add", p).contains("width.out_of_range"));
    }

    #[test]
    fn image_add_rejects_non_numeric_x() {
        let mut p = good_image_add();
        p["x"] = json!("oops");
        assert!(err_code("image_add", p).contains("x.missing_or_not_number"));
    }

    // -- image_move -------------------------------------------------------

    #[test]
    fn image_move_no_dims_is_ok() {
        let p = json!({
            "id": "22222222-2222-2222-2222-222222222222",
            "x": 0.0, "y": 0.0
        });
        assert!(validate("image_move", &p).is_ok());
    }

    #[test]
    fn image_move_both_dims_present_is_ok() {
        let p = json!({
            "id": "22222222-2222-2222-2222-222222222222",
            "x": 0.0, "y": 0.0,
            "width": 100.0, "height": 50.0
        });
        assert!(validate("image_move", &p).is_ok());
    }

    #[test]
    fn image_move_partial_dims_rejected() {
        let p = json!({
            "id": "22222222-2222-2222-2222-222222222222",
            "x": 0.0, "y": 0.0,
            "width": 100.0
        });
        assert!(err_code("image_move", p).contains("dims.partial"));
    }

    // -- image_remove -----------------------------------------------------

    #[test]
    fn image_remove_valid_uuid_passes() {
        let p = json!({"id": "33333333-3333-3333-3333-333333333333"});
        assert!(validate("image_remove", &p).is_ok());
    }

    #[test]
    fn image_remove_bad_uuid_rejected() {
        let p = json!({"id": "junk"});
        assert!(err_code("image_remove", p).contains("id.not_uuid"));
    }

    // -- avatar_move ------------------------------------------------------

    #[test]
    fn avatar_move_valid_passes() {
        let p = json!({
            "user_id": "44444444-4444-4444-4444-444444444444",
            "x": 1000.0, "y": 2000.0
        });
        assert!(validate("avatar_move", &p).is_ok());
    }

    #[test]
    fn avatar_move_rejects_out_of_range_y() {
        let p = json!({
            "user_id": "44444444-4444-4444-4444-444444444444",
            "x": 0.0, "y": 1.0e10
        });
        assert!(err_code("avatar_move", p).contains("out_of_range"));
    }

    #[test]
    fn avatar_move_rejects_missing_user_id() {
        let p = json!({"x": 0.0, "y": 0.0});
        assert!(err_code("avatar_move", p).contains("user_id.missing"));
    }

    // -- screenshare_move -------------------------------------------------

    #[test]
    fn screenshare_legacy_format_passes_without_coord_v() {
        let p = json!({
            "window_id": "win-1",
            "x": 100.0, "y": 50.0, "width": 800.0, "height": 600.0
        });
        assert!(validate("screenshare_move", &p).is_ok());
    }

    #[test]
    fn screenshare_legacy_format_passes_with_coord_v1() {
        let p = json!({
            "window_id": "win-1",
            "coord_v": 1,
            "x": 100.0, "y": 50.0, "width": 800.0, "height": 600.0
        });
        assert!(validate("screenshare_move", &p).is_ok());
    }

    #[test]
    fn screenshare_v2_format_passes() {
        let p = json!({
            "window_id": "win-2",
            "coord_v": 2,
            "x_norm": 0.25, "y_norm": 0.5, "w_norm": 0.4, "h_norm": 0.3
        });
        assert!(validate("screenshare_move", &p).is_ok());
    }

    #[test]
    fn screenshare_v2_rejects_x_norm_above_one() {
        let p = json!({
            "window_id": "win-2",
            "coord_v": 2,
            "x_norm": 1.5, "y_norm": 0.5, "w_norm": 0.4, "h_norm": 0.3
        });
        assert!(err_code("screenshare_move", p).contains("x_norm.out_of_range"));
    }

    #[test]
    fn screenshare_v2_rejects_negative_y_norm() {
        let p = json!({
            "window_id": "win-2",
            "coord_v": 2,
            "x_norm": 0.5, "y_norm": -0.1, "w_norm": 0.4, "h_norm": 0.3
        });
        assert!(err_code("screenshare_move", p).contains("y_norm.out_of_range"));
    }

    #[test]
    fn screenshare_rejects_unknown_coord_v() {
        let p = json!({
            "window_id": "win-2",
            "coord_v": 99,
            "x_norm": 0.5, "y_norm": 0.5, "w_norm": 0.4, "h_norm": 0.3
        });
        assert!(err_code("screenshare_move", p).contains("coord_v.unsupported"));
    }

    #[test]
    fn screenshare_rejects_empty_window_id() {
        let p = json!({
            "window_id": "",
            "x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0
        });
        assert!(err_code("screenshare_move", p).contains("window_id.empty"));
    }

    #[test]
    fn screenshare_rejects_too_long_window_id() {
        let long = "a".repeat(MAX_WINDOW_ID_LEN + 1);
        let p = json!({
            "window_id": long,
            "x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0
        });
        assert!(err_code("screenshare_move", p).contains("window_id.too_long"));
    }

    #[test]
    fn screenshare_legacy_rejects_non_numeric() {
        let p = json!({
            "window_id": "win",
            "x": "boom", "y": 0.0, "width": 100.0, "height": 100.0
        });
        assert!(err_code("screenshare_move", p).contains("missing_or_not_number"));
    }

    #[test]
    fn screenshare_legacy_rejects_out_of_range() {
        let p = json!({
            "window_id": "win",
            "x": 1.0e9, "y": 0.0, "width": 100.0, "height": 100.0
        });
        assert!(err_code("screenshare_move", p).contains("x.out_of_range"));
    }

    // -- unknown kind -----------------------------------------------------

    #[test]
    fn unknown_kind_is_passthrough_ok() {
        // Future kinds added to the allowlist before a schema lands must not
        // be accidentally blocked here.
        assert!(validate("future_kind", &json!({"whatever": 1})).is_ok());
    }

    // -- ValidationMode parsing covered alongside the mode enum (see canvas.rs).
}

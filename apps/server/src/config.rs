//! Server configuration from environment variables.

use std::env;
use std::net::IpAddr;

#[derive(Clone)]
pub struct Config {
    pub database_url: String,
    pub jwt_secret: String,
    pub host: String,
    pub port: u16,
    /// IPs of trusted reverse proxies whose `X-Real-IP` / `X-Forwarded-For`
    /// headers are honored for rate limiting.  Parsed from the
    /// `TRUSTED_PROXIES` env var (comma-separated IPs).  Empty by default,
    /// meaning proxy headers are **ignored**.
    pub trusted_proxies: Vec<IpAddr>,
}

impl Config {
    pub fn from_env() -> Self {
        let jwt_secret =
            env::var("JWT_SECRET").expect("JWT_SECRET environment variable must be set");
        assert!(
            jwt_secret.len() >= 32,
            "JWT_SECRET must be at least 32 characters for security"
        );

        let trusted_proxies: Vec<IpAddr> = env::var("TRUSTED_PROXIES")
            .unwrap_or_default()
            .split(',')
            .filter_map(|s| {
                let trimmed = s.trim();
                if trimmed.is_empty() {
                    return None;
                }
                match trimmed.parse::<IpAddr>() {
                    Ok(ip) => Some(ip),
                    Err(e) => {
                        tracing::warn!("Ignoring invalid TRUSTED_PROXIES entry '{trimmed}': {e}");
                        None
                    }
                }
            })
            .collect();

        if !trusted_proxies.is_empty() {
            tracing::info!("Trusted proxies: {:?}", trusted_proxies);
        }

        Self {
            database_url: env::var("DATABASE_URL")
                .expect("DATABASE_URL environment variable must be set"),
            jwt_secret,
            host: resolve_host(|k| env::var(k).ok()),
            port: resolve_port(|k| env::var(k).ok()),
            trusted_proxies,
        }
    }
}

/// Resolve the bind host, preferring `SERVER_HOST` and falling back to the
/// legacy `HOST` (with a deprecation warning) so existing self-hosters using
/// the bare `HOST=` form keep booting cleanly while new deployments adopt
/// the namespaced env name.  Defaults to `0.0.0.0` if neither is set (#532).
fn resolve_host<F: Fn(&str) -> Option<String>>(get: F) -> String {
    if let Some(v) = get("SERVER_HOST") {
        return v;
    }
    if let Some(v) = get("HOST") {
        tracing::warn!("HOST is deprecated; use SERVER_HOST instead (#532)");
        return v;
    }
    "0.0.0.0".into()
}

/// Resolve the bind port, preferring `SERVER_PORT` and falling back to the
/// legacy `PORT` (with a deprecation warning).  Unparseable values fall
/// through to the default `8080` and emit a warning so a typo'd value is
/// observable rather than silently ignored (#532).
fn resolve_port<F: Fn(&str) -> Option<String>>(get: F) -> u16 {
    fn parse_port_or_warn(name: &str, raw: &str) -> u16 {
        match raw.parse() {
            Ok(p) => p,
            Err(_) => {
                tracing::warn!("{name}='{raw}' is not a valid port; defaulting to 8080");
                8080
            }
        }
    }
    if let Some(v) = get("SERVER_PORT") {
        return parse_port_or_warn("SERVER_PORT", &v);
    }
    if let Some(v) = get("PORT") {
        tracing::warn!("PORT is deprecated; use SERVER_PORT instead (#532)");
        return parse_port_or_warn("PORT", &v);
    }
    8080
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_trusted_proxies_empty() {
        // Simulate empty env var
        let proxies: Vec<IpAddr> = ""
            .split(',')
            .filter_map(|s| {
                let t = s.trim();
                if t.is_empty() { None } else { t.parse().ok() }
            })
            .collect();
        assert!(proxies.is_empty());
    }

    #[test]
    fn parse_trusted_proxies_single() {
        let proxies: Vec<IpAddr> = "10.0.0.1"
            .split(',')
            .filter_map(|s| s.trim().parse().ok())
            .collect();
        assert_eq!(proxies, vec!["10.0.0.1".parse::<IpAddr>().unwrap()]);
    }

    #[test]
    fn parse_trusted_proxies_multiple_with_whitespace() {
        let proxies: Vec<IpAddr> = " 10.0.0.1 , 172.17.0.1 , ::1 "
            .split(',')
            .filter_map(|s| s.trim().parse().ok())
            .collect();
        assert_eq!(proxies.len(), 3);
        assert_eq!(proxies[0], "10.0.0.1".parse::<IpAddr>().unwrap());
        assert_eq!(proxies[1], "172.17.0.1".parse::<IpAddr>().unwrap());
        assert_eq!(proxies[2], "::1".parse::<IpAddr>().unwrap());
    }

    #[test]
    fn parse_trusted_proxies_skips_invalid() {
        let proxies: Vec<IpAddr> = "10.0.0.1, not-an-ip, 172.17.0.1"
            .split(',')
            .filter_map(|s| {
                let t = s.trim();
                if t.is_empty() { None } else { t.parse().ok() }
            })
            .collect();
        assert_eq!(proxies.len(), 2);
    }

    // -----------------------------------------------------------------
    // #532: SERVER_HOST/SERVER_PORT precedence + legacy HOST/PORT fallback.
    // Closure-based fake env keeps these tests parallel-safe -- no
    // std::env::set_var, which would race against the other test threads.
    // -----------------------------------------------------------------
    use std::collections::HashMap;

    fn fake_env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let map: HashMap<String, String> = pairs
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect();
        move |k: &str| map.get(k).cloned()
    }

    #[test]
    fn resolve_host_prefers_server_host_over_legacy() {
        let host = resolve_host(fake_env(&[("SERVER_HOST", "1.2.3.4"), ("HOST", "5.6.7.8")]));
        assert_eq!(host, "1.2.3.4");
    }

    #[test]
    fn resolve_host_falls_back_to_legacy_host() {
        let host = resolve_host(fake_env(&[("HOST", "5.6.7.8")]));
        assert_eq!(host, "5.6.7.8");
    }

    #[test]
    fn resolve_host_defaults_when_neither_set() {
        let host = resolve_host(fake_env(&[]));
        assert_eq!(host, "0.0.0.0");
    }

    #[test]
    fn resolve_port_prefers_server_port_over_legacy() {
        let port = resolve_port(fake_env(&[("SERVER_PORT", "9090"), ("PORT", "1234")]));
        assert_eq!(port, 9090);
    }

    #[test]
    fn resolve_port_falls_back_to_legacy_port() {
        let port = resolve_port(fake_env(&[("PORT", "1234")]));
        assert_eq!(port, 1234);
    }

    #[test]
    fn resolve_port_defaults_when_neither_set() {
        let port = resolve_port(fake_env(&[]));
        assert_eq!(port, 8080);
    }

    #[test]
    fn resolve_port_defaults_on_unparseable_value() {
        let port = resolve_port(fake_env(&[("SERVER_PORT", "not-a-number")]));
        assert_eq!(port, 8080);
    }

    #[test]
    fn resolve_port_legacy_unparseable_falls_through_to_default() {
        // Belt-and-suspenders branch coverage: same parse logic on the legacy
        // arm should also default rather than panic if a future refactor
        // diverges the two paths.
        let port = resolve_port(fake_env(&[("PORT", "garbage")]));
        assert_eq!(port, 8080);
    }
}

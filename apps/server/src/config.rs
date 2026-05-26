//! Server configuration from environment variables.

use ipnet::IpNet;
use std::env;

#[derive(Clone)]
pub struct Config {
    pub database_url: String,
    pub jwt_secret: String,
    pub host: String,
    pub port: u16,
    /// CIDRs (or individual IPs) of trusted reverse proxies whose
    /// `X-Real-IP` / `X-Forwarded-For` headers are honored for rate limiting.
    /// Parsed from the `TRUSTED_PROXIES` env var (comma-separated CIDRs or
    /// plain IPs, e.g. `127.0.0.1,172.16.0.0/12`).  Empty by default, meaning
    /// proxy headers are **ignored** and the peer IP is used directly.
    pub trusted_proxies: Vec<IpNet>,
}

impl Config {
    pub fn from_env() -> Self {
        let jwt_secret =
            env::var("JWT_SECRET").expect("JWT_SECRET environment variable must be set");
        assert!(
            jwt_secret.len() >= 32,
            "JWT_SECRET must be at least 32 characters for security"
        );

        let trusted_proxies: Vec<IpNet> = env::var("TRUSTED_PROXIES")
            .unwrap_or_default()
            .split(',')
            .filter_map(|s| {
                let trimmed = s.trim();
                if trimmed.is_empty() {
                    return None;
                }
                // Normalise bare IPs to /32 or /128 host routes.
                trimmed
                    .parse::<IpNet>()
                    .ok()
                    .or_else(|| trimmed.parse::<std::net::IpAddr>().ok().map(IpNet::from))
                    .or_else(|| {
                        tracing::warn!(
                            "Ignoring invalid TRUSTED_PROXIES entry '{trimmed}': \
                             expected an IP address or CIDR (e.g. 127.0.0.1 or 172.16.0.0/12)"
                        );
                        None
                    })
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

/// Returns whether registration is open on this server.
///
/// Read once per call so operators can change the env without a restart in
/// development.  Defaults to `true` (open) for backwards compatibility with
/// existing self-hosted instances; set `REGISTRATION_OPEN=false` (or `0`,
/// `no`, `off`) to lock down a server.  Used by both `GET /api/server-info`
/// (which advertises the policy) and `POST /api/auth/register` (which
/// enforces it).
pub fn registration_open() -> bool {
    parse_registration_open(std::env::var("REGISTRATION_OPEN").ok())
}

/// Parser split out so tests can exercise the truthiness rules without
/// touching the process-wide env (which would race with parallel tests).
fn parse_registration_open(raw: Option<String>) -> bool {
    match raw {
        Some(v) => !matches!(
            v.trim().to_lowercase().as_str(),
            "false" | "0" | "no" | "off"
        ),
        None => true,
    }
}

/// Resolve the bind host, preferring `SERVER_HOST` and falling back to the
/// legacy `HOST` (with a deprecation warning) so existing self-hosters using
/// the bare `HOST=` form keep booting cleanly while new deployments adopt
/// the namespaced env name.  Defaults to `0.0.0.0` if neither is set.
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
/// observable rather than silently ignored.
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
    use ipnet::IpNet;
    use std::net::IpAddr;

    /// Helper: parse a `TRUSTED_PROXIES`-style string using the same logic as
    /// `Config::from_env` without touching the real process environment.
    fn parse_proxies(raw: &str) -> Vec<IpNet> {
        raw.split(',')
            .filter_map(|s| {
                let t = s.trim();
                if t.is_empty() {
                    return None;
                }
                t.parse::<IpNet>()
                    .ok()
                    .or_else(|| t.parse::<IpAddr>().ok().map(IpNet::from))
            })
            .collect()
    }

    #[test]
    fn parse_trusted_proxies_empty() {
        assert!(parse_proxies("").is_empty());
    }

    #[test]
    fn parse_trusted_proxies_single_bare_ip() {
        let proxies = parse_proxies("10.0.0.1");
        assert_eq!(proxies.len(), 1);
        // Bare IP becomes a host route.
        assert!(proxies[0].contains(&"10.0.0.1".parse::<IpAddr>().unwrap()));
    }

    #[test]
    fn parse_trusted_proxies_cidr() {
        let proxies = parse_proxies("172.16.0.0/12");
        assert_eq!(proxies.len(), 1);
        // Addresses inside the CIDR must match.
        assert!(proxies[0].contains(&"172.16.0.1".parse::<IpAddr>().unwrap()));
        assert!(proxies[0].contains(&"172.31.255.254".parse::<IpAddr>().unwrap()));
        // Address outside the CIDR must not match.
        assert!(!proxies[0].contains(&"172.32.0.1".parse::<IpAddr>().unwrap()));
    }

    #[test]
    fn parse_trusted_proxies_mixed_ip_and_cidr() {
        let proxies = parse_proxies("127.0.0.1,172.16.0.0/12,172.20.0.0/16");
        assert_eq!(proxies.len(), 3);
        // 127.0.0.1 host route
        assert!(proxies[0].contains(&"127.0.0.1".parse::<IpAddr>().unwrap()));
        // 172.16.0.0/12 includes 172.20.x.x
        assert!(proxies[1].contains(&"172.20.0.1".parse::<IpAddr>().unwrap()));
        // Narrower /16 subnet
        assert!(proxies[2].contains(&"172.20.0.1".parse::<IpAddr>().unwrap()));
        assert!(!proxies[2].contains(&"172.21.0.1".parse::<IpAddr>().unwrap()));
    }

    #[test]
    fn parse_trusted_proxies_multiple_with_whitespace() {
        let proxies = parse_proxies(" 10.0.0.1 , 172.17.0.1 , ::1 ");
        assert_eq!(proxies.len(), 3);
        assert!(proxies[0].contains(&"10.0.0.1".parse::<IpAddr>().unwrap()));
        assert!(proxies[1].contains(&"172.17.0.1".parse::<IpAddr>().unwrap()));
        assert!(proxies[2].contains(&"::1".parse::<IpAddr>().unwrap()));
    }

    #[test]
    fn parse_trusted_proxies_skips_invalid() {
        let proxies = parse_proxies("10.0.0.1, not-an-ip, 172.17.0.1");
        assert_eq!(proxies.len(), 2);
    }

    // SERVER_HOST/PORT precedence + legacy fallback.
    // Closure fake-env keeps tests parallel-safe (no set_var races).
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
        // Branch coverage for the legacy arm's parse defaulting.
        let port = resolve_port(fake_env(&[("PORT", "garbage")]));
        assert_eq!(port, 8080);
    }

    // -----------------------------------------------------------------
    // REGISTRATION_OPEN parsing rules.
    // -----------------------------------------------------------------

    #[test]
    fn registration_open_defaults_true_when_unset() {
        assert!(parse_registration_open(None));
    }

    #[test]
    fn registration_open_false_for_falsy_strings() {
        for v in ["false", "FALSE", "False", "0", "no", "NO", "off", "Off"] {
            assert!(
                !parse_registration_open(Some(v.into())),
                "{v} should parse as closed"
            );
        }
    }

    #[test]
    fn registration_open_true_for_truthy_strings() {
        for v in ["true", "1", "yes", "on", "open", "anything-else"] {
            assert!(
                parse_registration_open(Some(v.into())),
                "{v} should parse as open"
            );
        }
    }

    #[test]
    fn registration_open_trims_whitespace() {
        assert!(!parse_registration_open(Some("  false  ".into())));
        assert!(!parse_registration_open(Some("\tno\n".into())));
    }
}

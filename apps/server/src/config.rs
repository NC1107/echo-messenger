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
            host: env::var("HOST").unwrap_or_else(|_| "0.0.0.0".into()),
            port: env::var("PORT")
                .ok()
                .and_then(|p| p.parse().ok())
                .unwrap_or(8080),
            trusted_proxies,
        }
    }
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
}

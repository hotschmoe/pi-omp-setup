//! Runtime configuration only: callers must never log the decrypted configuration.
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};

pub const PROVIDER: &str = "hotschmoe-local";
pub const DEFAULT_MODEL: &str = "hotschmoe-dd";

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ModelConfig {
    pub endpoint: String,
    pub api_key: String,
    #[serde(default = "default_model")]
    pub model_id: String,
}
fn default_model() -> String {
    DEFAULT_MODEL.into()
}

fn base_url(config: &ModelConfig) -> Result<String> {
    let mut url =
        url::Url::parse(&config.endpoint).map_err(|_| anyhow::anyhow!("Invalid model endpoint"))?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || !matches!(url.path(), "" | "/" | "/v1" | "/v1/")
    {
        bail!("Model endpoint must be an HTTPS origin or HTTPS /v1 base URL, without credentials, query, or fragment");
    }
    if config.api_key.trim().is_empty()
        || config.api_key.trim_start().starts_with('!')
        || config.api_key.chars().any(char::is_control)
    {
        bail!("Invalid model API key");
    }
    if config.model_id.is_empty()
        || config.model_id.chars().any(|c| {
            c.is_whitespace() || c.is_control() || matches!(c, ':' | '*' | '?' | '>' | '@')
        })
    {
        bail!("Invalid model identifier");
    }
    url.set_path("/v1");
    Ok(url.to_string())
}

/// Validate a decrypted payload without touching client files or the network.
pub fn validate(config: &ModelConfig) -> Result<()> {
    base_url(config).map(|_| ())
}

fn check_path(path: &Path) -> Result<()> {
    for ancestor in path.ancestors() {
        match fs::symlink_metadata(ancestor) {
            Ok(meta) if meta.file_type().is_symlink() => {
                bail!("Refusing configuration path through a symbolic link")
            }
            Ok(_) => (),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
            Err(_) => bail!("Cannot inspect configuration path"),
        }
    }
    Ok(())
}

#[cfg(unix)]
fn private(path: &Path, directory: bool) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(
        path,
        fs::Permissions::from_mode(if directory { 0o700 } else { 0o600 }),
    )
    .context("Cannot secure configuration permissions")
}

#[cfg(windows)]
fn private(path: &Path, directory: bool) -> Result<()> {
    use std::process::Command;
    let identity = Command::new("whoami")
        .args(["/user", "/fo", "csv", "/nh"])
        .output()
        .context("Cannot identify current Windows user")?;
    if !identity.status.success() {
        bail!("Cannot identify current Windows user");
    }
    let text =
        String::from_utf8(identity.stdout).context("Cannot identify current Windows user")?;
    let sid = text
        .trim()
        .split(',')
        .next_back()
        .unwrap_or("")
        .trim_matches('"');
    if !sid.starts_with("S-1-")
        || !sid
            .chars()
            .all(|c| c.is_ascii_digit() || c == 'S' || c == '-')
    {
        bail!("Cannot identify current Windows user");
    }
    let grant = format!("*{sid}:{}F", if directory { "(OI)(CI)" } else { "" });
    // Reset explicit ACL entries, then remove inheritance and grant only this user.
    for args in [
        vec!["/reset"],
        vec!["/inheritance:r", "/grant:r", grant.as_str()],
    ] {
        let output = Command::new("icacls")
            .arg(path)
            .args(args)
            .output()
            .context("Cannot secure Windows configuration permissions")?;
        if !output.status.success() {
            bail!("Cannot secure Windows configuration permissions");
        }
    }
    Ok(())
}

fn directory(path: &Path) -> Result<()> {
    check_path(path)?;
    if !path.exists() {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            if !parent.exists() {
                directory(parent)?;
            }
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            fs::DirBuilder::new()
                .mode(0o700)
                .create(path)
                .context("Cannot create configuration directory")?;
        }
        #[cfg(not(unix))]
        fs::create_dir(path).context("Cannot create configuration directory")?;
    }
    if !path.is_dir() {
        bail!("Configuration directory is not a directory");
    }
    private(path, true)
}

fn read(path: &Path, yaml: bool) -> Result<Value> {
    check_path(path)?;
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if !metadata.is_file() {
            bail!("Existing configuration must be a regular file");
        }
    }
    let data = match fs::read(path) {
        Ok(data) => data,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(json!({})),
        Err(_) => bail!("Cannot read existing configuration"),
    };
    let value: Value = if yaml {
        serde_yaml_ng::from_slice(&data)
            .map_err(|_| anyhow::anyhow!("Existing YAML configuration is malformed"))?
    } else {
        serde_json::from_slice(&data)
            .map_err(|_| anyhow::anyhow!("Existing JSON configuration is malformed"))?
    };
    if !value.is_object() {
        bail!("Existing configuration must contain an object");
    }
    Ok(value)
}

fn object(value: &mut Value) -> Result<&mut Map<String, Value>> {
    value
        .as_object_mut()
        .context("Existing configuration field must contain an object")
}
fn child<'a>(value: &'a mut Value, key: &str) -> Result<&'a mut Value> {
    let entry = object(value)?.entry(key).or_insert_with(|| json!({}));
    if !entry.is_object() {
        bail!("Existing configuration field must contain an object");
    }
    Ok(entry)
}

fn merge_models(value: &mut Value, config: &ModelConfig, endpoint: &str) -> Result<()> {
    let provider = child(child(value, "providers")?, PROVIDER)?;
    let obj = object(provider)?;
    obj.insert("baseUrl".into(), json!(endpoint));
    obj.insert("apiKey".into(), json!(config.api_key));
    obj.insert("api".into(), json!("openai-completions"));
    let models = obj
        .entry("models")
        .or_insert_with(|| json!([]))
        .as_array_mut()
        .context("Existing provider models must contain an array")?;
    for model in models.iter() {
        if !model.is_object() || model.get("id").and_then(Value::as_str).is_none() {
            bail!("Existing model entry must contain an identifier");
        }
    }
    let index = models.iter().position(|m| m["id"] == config.model_id);
    if models.iter().filter(|m| m["id"] == config.model_id).count() > 1 {
        bail!("Existing provider contains duplicate model identifiers");
    }
    let index = index.unwrap_or_else(|| {
        models.push(json!({}));
        models.len() - 1
    });
    let model = &mut models[index];
    for (key, value) in json!({
        "id": config.model_id, "name": config.model_id, "api": "openai-completions",
        "reasoning": true, "input": ["text"], "contextWindow": 200000, "maxTokens": 32768,
        "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}
    })
    .as_object()
    .unwrap()
    {
        object(model)?.insert(key.clone(), value.clone());
    }
    let compat = object(child(model, "compat")?)?;
    for (key, value) in [
        ("supportsReasoningEffort", json!(false)),
        ("supportsDeveloperRole", json!(false)),
        ("supportsStore", json!(false)),
        ("maxTokensField", json!("max_tokens")),
    ] {
        compat.insert(key.into(), value);
    }
    Ok(())
}

struct Change {
    path: PathBuf,
    old: Option<Vec<u8>>,
    data: Vec<u8>,
}
fn stage(path: PathBuf, before: Value, after: Value, yaml: bool) -> Result<Option<Change>> {
    check_path(&path)?;
    if before == after && path.exists() {
        return Ok(None);
    }
    let old = match fs::read(&path) {
        Ok(data) => Some(data),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(_) => bail!("Cannot read existing configuration"),
    };
    let data = if yaml {
        serde_yaml_ng::to_string(&after)
            .map_err(|_| anyhow::anyhow!("Cannot serialize configuration"))?
            .into_bytes()
    } else {
        let mut data =
            serde_json::to_vec_pretty(&after).context("Cannot serialize configuration")?;
        data.push(b'\n');
        data
    };
    Ok(Some(Change { path, old, data }))
}

fn atomic(path: &Path, data: &[u8], no_clobber: bool) -> Result<()> {
    check_path(path)?;
    let parent = path.parent().context("Configuration path needs a parent")?;
    let mut temp = tempfile::NamedTempFile::new_in(parent).context("Cannot stage configuration")?;
    private(temp.path(), false)?;
    temp.write_all(data)
        .context("Cannot write staged configuration")?;
    temp.as_file()
        .sync_all()
        .context("Cannot sync staged configuration")?;
    if no_clobber {
        temp.persist_noclobber(path)
            .map_err(|_| anyhow::anyhow!("Cannot save configuration backup"))?;
    } else {
        temp.persist(path)
            .map_err(|_| anyhow::anyhow!("Cannot replace configuration"))?;
    }
    Ok(())
}

fn select_yaml(dir: &Path, stem: &str) -> Result<(PathBuf, Value)> {
    for extension in ["yml", "yaml"] {
        let path = dir.join(format!("{stem}.{extension}"));
        check_path(&path)?;
        if path.exists() {
            return Ok((path.clone(), read(&path, true)?));
        }
    }
    let legacy = dir.join(if stem == "config" {
        "settings.json"
    } else {
        "models.json"
    });
    if stem == "config" && dir.join("agent.db").exists() {
        bail!(
            "Run omp once to migrate legacy database settings before configuring this installation"
        );
    }
    Ok((dir.join(format!("{stem}.yml")), read(&legacy, false)?))
}

/// Merge the private model into both clients. Never contacts the endpoint.
/// All documents are parsed and validated before any configuration is replaced.
pub fn configure(config: &ModelConfig, pi_dir: &Path, omp_dir: &Path) -> Result<()> {
    let endpoint = base_url(config)?;
    check_path(pi_dir)?;
    check_path(omp_dir)?;
    let mut changes = Vec::new();
    for (path, before, yaml, models) in [
        (
            pi_dir.join("models.json"),
            read(&pi_dir.join("models.json"), false)?,
            false,
            true,
        ),
        (
            pi_dir.join("settings.json"),
            read(&pi_dir.join("settings.json"), false)?,
            false,
            false,
        ),
        {
            let (p, v) = select_yaml(omp_dir, "models")?;
            (p, v, true, true)
        },
        {
            let (p, v) = select_yaml(omp_dir, "config")?;
            (p, v, true, false)
        },
    ] {
        let mut after = before.clone();
        if models {
            merge_models(&mut after, config, &endpoint)?;
        } else if yaml {
            object(child(&mut after, "modelRoles")?)?.insert(
                "default".into(),
                json!(format!("{PROVIDER}/{}", config.model_id)),
            );
        } else {
            object(&mut after)?.insert("defaultProvider".into(), json!(PROVIDER));
            object(&mut after)?.insert("defaultModel".into(), json!(config.model_id));
        }
        if let Some(change) = stage(path, before, after, yaml)? {
            changes.push(change);
        }
    }
    directory(pi_dir)?;
    directory(omp_dir)?;
    for change in changes {
        check_path(&change.path)?;
        if let Some(old) = &change.old {
            // Numbered, non-overwriting backups retain every previous configuration.
            let mut saved = false;
            for n in 0..10000 {
                let suffix = if n == 0 {
                    ".bak".into()
                } else {
                    format!(".bak.{n}")
                };
                let mut name = change.path.as_os_str().to_owned();
                name.push(suffix);
                let backup = PathBuf::from(name);
                if fs::symlink_metadata(&backup).is_ok() {
                    continue;
                }
                atomic(&backup, old, true)?;
                saved = true;
                break;
            }
            if !saved {
                bail!("Too many existing configuration backups");
            }
        }
        atomic(&change.path, &change.data, false)?;
    }
    // Also harden files when content was already correct.
    for path in [
        pi_dir.join("models.json"),
        pi_dir.join("settings.json"),
        select_yaml(omp_dir, "models")?.0,
        select_yaml(omp_dir, "config")?.0,
    ] {
        private(&path, false)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn scratch() -> tempfile::TempDir {
        let parent = fs::canonicalize(std::env::temp_dir()).unwrap();
        tempfile::tempdir_in(parent).unwrap()
    }
    fn config() -> ModelConfig {
        ModelConfig {
            endpoint: "https://example.invalid/".into(),
            api_key: "test-placeholder".into(),
            model_id: DEFAULT_MODEL.into(),
        }
    }
    #[test]
    fn fresh_defaults_and_idempotence() {
        let tmp = scratch();
        let pi = tmp.path().join("pi");
        let omp = tmp.path().join("omp");
        configure(&config(), &pi, &omp).unwrap();
        assert_eq!(
            read(&pi.join("settings.json"), false).unwrap()["defaultModel"],
            DEFAULT_MODEL
        );
        let m = read(&omp.join("models.yml"), true).unwrap();
        assert_eq!(
            m["providers"][PROVIDER]["baseUrl"],
            "https://example.invalid/v1"
        );
        assert_eq!(
            m["providers"][PROVIDER]["models"][0]["contextWindow"],
            200000
        );
        assert_eq!(
            read(&omp.join("config.yml"), true).unwrap()["modelRoles"]["default"],
            "hotschmoe-local/hotschmoe-dd"
        );
        configure(&config(), &pi, &omp).unwrap();
        assert!(!pi.join("models.json.bak").exists());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&pi).unwrap().permissions().mode() & 0o777,
                0o700
            );
            assert_eq!(
                fs::metadata(pi.join("models.json"))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
    }
    #[test]
    fn preserves_and_backs_up() {
        let tmp = scratch();
        let pi = tmp.path().join("pi");
        let omp = tmp.path().join("omp");
        directory(&pi).unwrap();
        directory(&omp).unwrap();
        let original = br#"{"theme":"dark","custom":{"a":1}}"#;
        fs::write(pi.join("settings.json"), original).unwrap();
        fs::write(
            omp.join("config.yaml"),
            "modelRoles:\n  smol: existing/model\ntheme:\n  dark: custom\n",
        )
        .unwrap();
        fs::write(pi.join("auth.json"), "opaque unchanged bytes").unwrap();
        fs::write(
            omp.join("models.json"),
            r#"{"providers":{"other":{"apiKey":"keep","models":[]}}}"#,
        )
        .unwrap();
        configure(&config(), &pi, &omp).unwrap();
        assert_eq!(fs::read(pi.join("settings.json.bak")).unwrap(), original);
        assert_eq!(
            read(&pi.join("settings.json"), false).unwrap()["custom"]["a"],
            1
        );
        assert_eq!(
            read(&omp.join("config.yaml"), true).unwrap()["modelRoles"]["smol"],
            "existing/model"
        );
        assert_eq!(
            read(&omp.join("models.yml"), true).unwrap()["providers"]["other"]["apiKey"],
            "keep"
        );
        assert_eq!(
            fs::read_to_string(pi.join("auth.json")).unwrap(),
            "opaque unchanged bytes"
        );
        let mut updated = config();
        updated.api_key = "changed-placeholder".into();
        configure(&updated, &pi, &omp).unwrap();
        configure(&config(), &pi, &omp).unwrap();
        assert!(pi.join("models.json.bak.1").exists());
    }
    #[test]
    fn rejects_bad_shape_before_writing() {
        for bad in [
            "not json",
            "[]",
            "null",
            "{\"providers\":[]}",
            "{\"providers\":{\"hotschmoe-local\":{\"models\":{}}}}",
        ] {
            let tmp = scratch();
            let pi = tmp.path().join("pi");
            let omp = tmp.path().join("omp");
            directory(&pi).unwrap();
            fs::write(pi.join("models.json"), bad).unwrap();
            assert!(configure(&config(), &pi, &omp).is_err());
            assert_eq!(fs::read_to_string(pi.join("models.json")).unwrap(), bad);
            assert!(!omp.exists());
        }
    }
    #[test]
    fn validates_all_documents_before_replacing_any() {
        let tmp = scratch();
        let pi = tmp.path().join("pi");
        let omp = tmp.path().join("omp");
        directory(&pi).unwrap();
        directory(&omp).unwrap();
        fs::write(pi.join("models.json"), "{}").unwrap();
        fs::write(omp.join("config.yml"), "modelRoles: []\n").unwrap();
        assert!(configure(&config(), &pi, &omp).is_err());
        assert_eq!(fs::read_to_string(pi.join("models.json")).unwrap(), "{}");
        assert!(!pi.join("settings.json").exists());
        assert!(!pi.join("models.json.bak").exists());
    }
    #[test]
    fn preserves_other_models_and_compat_options() {
        let mut value = json!({"providers": {PROVIDER: {
            "headers": {"X-Custom": "preserved"},
            "models": [
                {"id": "other", "name": "Existing"},
                {"id": DEFAULT_MODEL, "compat": {"supportsUsageInStreaming": false}, "headers": {"X-Model": "preserved"}}
            ]
        }}});
        merge_models(&mut value, &config(), "https://example.invalid/v1").unwrap();
        let provider = &value["providers"][PROVIDER];
        assert_eq!(provider["headers"]["X-Custom"], "preserved");
        assert_eq!(provider["models"][0]["name"], "Existing");
        assert_eq!(
            provider["models"][1]["compat"]["supportsUsageInStreaming"],
            false
        );
        assert_eq!(
            provider["models"][1]["compat"]["supportsReasoningEffort"],
            false
        );
        assert_eq!(provider["models"][1]["headers"]["X-Model"], "preserved");
    }
    #[test]
    fn rejects_secret_commands_and_bad_urls_without_echoing() {
        let mut c = config();
        for endpoint in [
            "http://example.invalid",
            "https://secret@example.invalid",
            "https://example.invalid/private",
            "https://example.invalid?secret",
        ] {
            c.endpoint = endpoint.into();
            let error = base_url(&c).unwrap_err().to_string();
            assert!(!error.contains("secret"));
        }
        c = config();
        c.api_key = "!run-secret-command".into();
        assert!(base_url(&c).is_err());
        let c: ModelConfig = serde_json::from_value(
            json!({"endpoint":"https://example.invalid","api_key":"placeholder"}),
        )
        .unwrap();
        assert_eq!(c.model_id, DEFAULT_MODEL);
    }
    #[cfg(unix)]
    #[test]
    fn refuses_symlinks_and_preserves_target() {
        use std::os::unix::fs::symlink;
        let tmp = scratch();
        let pi = tmp.path().join("pi");
        let omp = tmp.path().join("omp");
        directory(&pi).unwrap();
        let target = tmp.path().join("target");
        fs::write(&target, "{}").unwrap();
        symlink(&target, pi.join("models.json")).unwrap();
        assert!(configure(&config(), &pi, &omp).is_err());
        assert_eq!(fs::read_to_string(target).unwrap(), "{}");
        let alias = tmp.path().join("alias");
        symlink(&pi, &alias).unwrap();
        assert!(configure(&config(), &alias, &omp).is_err());
    }
}

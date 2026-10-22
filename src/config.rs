//! Runtime configuration only: callers must never log the decrypted configuration.
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::{
    collections::HashSet,
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
pub(crate) fn private(path: &Path, directory: bool) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(
        path,
        fs::Permissions::from_mode(if directory { 0o700 } else { 0o600 }),
    )
    .context("Cannot secure configuration permissions")
}

#[cfg(windows)]
pub(crate) fn private(path: &Path, directory: bool) -> Result<()> {
    // Construct a fresh protected DACL and apply it once: never reset an existing
    // secret file to broader inherited permissions, even temporarily. Use only
    // .NET APIs, since PowerShell module lookup can inherit another host's paths.
    let script = r#"$ErrorActionPreference='Stop';
$p=[IO.Path]::GetFullPath($env:PI_OMP_PRIVATE_PATH);
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User;
if ($env:PI_OMP_PRIVATE_DIRECTORY -eq '1') {
    $acl=[Security.AccessControl.DirectorySecurity]::new();
    $inherit=[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit';
} else {
    $acl=[Security.AccessControl.FileSecurity]::new();
    $inherit=[Security.AccessControl.InheritanceFlags]::None;
}
$acl.SetAccessRuleProtection($true,$false);
$rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow);
$acl.AddAccessRule($rule);
if ($env:PI_OMP_PRIVATE_DIRECTORY -eq '1') {
    [IO.Directory]::SetAccessControl($p,$acl);
} else {
    [IO.File]::SetAccessControl($p,$acl);
}"#;
    let output = std::process::Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", script])
        .env("PI_OMP_PRIVATE_PATH", path)
        .env(
            "PI_OMP_PRIVATE_DIRECTORY",
            if directory { "1" } else { "0" },
        )
        .output()
        .context("Cannot secure Windows configuration permissions")?;
    if !output.status.success() {
        bail!("Cannot secure Windows configuration permissions");
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

fn read_doc(path: &Path, format: DocFormat) -> Result<Value> {
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
    let value: Value = match format {
        DocFormat::Json => serde_json::from_slice(&data)
            .map_err(|_| anyhow::anyhow!("Existing JSON configuration is malformed"))?,
        DocFormat::Yaml => serde_yaml::from_slice(&data)
            .map_err(|_| anyhow::anyhow!("Existing YAML configuration is malformed"))?,
    };
    if !value.is_object() {
        bail!("Existing configuration must contain an object");
    }
    Ok(value)
}
fn read(path: &Path) -> Result<Value> {
    read_doc(path, DocFormat::Json)
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

fn provider_body(config: &ModelConfig, endpoint: &str) -> Value {
    json!({
        "baseUrl": endpoint,
        "apiKey": config.api_key,
        "api": "openai-completions",
        "models": [{
            "id": config.model_id, "name": config.model_id, "api": "openai-completions",
            "reasoning": true, "input": ["text", "image"], "contextWindow": 200000,
            "maxTokens": 32768,
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
            "compat": {
                "supportsReasoningEffort": true,
                "supportsDeveloperRole": false,
                "supportsStore": false,
                "maxTokensField": "max_tokens",
                "thinkingFormat": "chat-template",
                "thinkingTokenBudgetField": "thinking_token_budget",
                "chatTemplateKwargs": {
                    "enable_thinking": {"$var": "thinking.enabled"},
                    "preserve_thinking": true,
                    "reasoning_effort": {"$var": "thinking.effort"}
                }
            }
        }]
    })
}

fn selector(config: &ModelConfig) -> String {
    format!("{PROVIDER}/{}", config.model_id)
}

/// Model id plus `provider/id`, so roles and allow-lists can be retargeted.
fn model_refs(providers: &Value) -> Result<HashSet<String>> {
    let mut refs = HashSet::new();
    let Some(map) = providers.as_object() else {
        if providers.is_null() {
            return Ok(refs);
        }
        bail!("Existing providers field must contain an object");
    };
    for (provider, body) in map {
        if !body.is_object() {
            bail!("Existing provider entry must contain an object");
        }
        match body.get("models") {
            None => {}
            Some(Value::Array(models)) => {
                for model in models {
                    let Some(id) = model.get("id").and_then(Value::as_str) else {
                        bail!("Existing model entry must contain an identifier");
                    };
                    if id.is_empty() {
                        bail!("Existing model entry must contain an identifier");
                    }
                    refs.insert(id.to_string());
                    refs.insert(format!("{provider}/{id}"));
                }
            }
            Some(_) => bail!("Existing provider models must contain an array"),
        }
    }
    Ok(refs)
}

fn split_role(value: &str) -> (&str, Option<&str>) {
    const LEVELS: [&str; 6] = ["minimal", "low", "medium", "high", "xhigh", "max"];
    if let Some((model, level)) = value.rsplit_once(':') {
        if LEVELS.contains(&level) {
            return (model, Some(level));
        }
    }
    (value, None)
}

fn names_removed(value: &str, removed: &HashSet<String>) -> bool {
    let (model, _) = split_role(value);
    removed.contains(value) || removed.contains(model)
}

fn is_current_model(text: &str, model_id: &str, selector: &str) -> bool {
    let (model, _) = split_role(text);
    model == model_id || text == model_id || model == selector || text == selector
}
fn retarget_list(list: &mut Value, removed: &HashSet<String>, model_id: &str, selector: &str) {
    let Some(items) = list.as_array() else {
        return;
    };
    let mut next = Vec::new();
    let mut saw_current = false;
    for item in items {
        let Some(text) = item.as_str() else {
            next.push(item.clone());
            continue;
        };
        if names_removed(text, removed) {
            continue;
        }
        if is_current_model(text, model_id, selector) {
            saw_current = true;
        }
        next.push(item.clone());
    }
    if !items.is_empty() && !saw_current {
        next.push(json!(model_id));
    }
    *list = json!(next);
}

/// Drop every custom provider, then install only the current model.
/// Returns selectors and ids that were removed so settings can be retargeted.
fn replace_models(value: &mut Value, config: &ModelConfig, endpoint: &str) -> Result<HashSet<String>> {
    let root = object(value)?;
    let removed = model_refs(root.get("providers").unwrap_or(&Value::Null))?;
    root.insert("providers".into(), json!({ PROVIDER: provider_body(config, endpoint) }));
    let mut removed = removed;
    removed.remove(&config.model_id);
    removed.remove(&selector(config));
    Ok(removed)
}

fn assign_roles(settings: &mut Value, config: &ModelConfig, removed: &HashSet<String>) -> Result<()> {
    let selector = selector(config);
    let roles = child(settings, "modelRoles")?;
    object(roles)?.insert("default".into(), json!(&selector));
    object(roles)?.insert("vision".into(), json!(&selector));
    let keys: Vec<String> = object(roles)?.keys().cloned().collect();
    for key in keys {
        if key == "default" || key == "vision" {
            continue;
        }
        let text = match object(roles)?.get(&key).and_then(Value::as_str) {
            Some(text) => text.to_string(),
            None => continue,
        };
        if !names_removed(&text, removed) {
            continue;
        }
        let (_, level) = split_role(&text);
        let updated = match level {
            Some(level) => format!("{selector}:{level}"),
            None => selector.clone(),
        };
        object(roles)?.insert(key, json!(updated));
    }
    Ok(())
}

fn retarget_settings(settings: &mut Value, config: &ModelConfig, removed: &HashSet<String>) -> Result<()> {
    assign_roles(settings, config, removed)?;
    let selector = selector(config);
    for key in ["enabledModels", "cycleOrder"] {
        let is_array = object(settings)?.get(key).is_some_and(Value::is_array);
        if is_array {
            retarget_list(
                object(settings)?.get_mut(key).unwrap(),
                removed,
                &config.model_id,
                &selector,
            );
        }
    }
    // Drop retired ids and never leave the current model disabled.
    let model_id = config.model_id.clone();
    let disable = object(settings)?.get("disabledModels").is_some_and(Value::is_array);
    if disable {
        let disabled = object(settings)?
            .get_mut("disabledModels")
            .unwrap()
            .as_array_mut()
            .unwrap();
        disabled.retain(|item| match item.as_str() {
            Some(text) => !is_current_model(text, &model_id, &selector) && !names_removed(text, removed),
            None => true,
        });
    }
    let root = object(settings)?;
    if !root.contains_key("defaultThinkingLevel") {
        root.insert("defaultThinkingLevel".into(), json!("medium"));
    }
    if !object(child(settings, "thinkingBudgets")?)?.contains_key("medium") {
        object(child(settings, "thinkingBudgets")?)?.insert("medium".into(), json!(8192));
    }
    if !object(child(settings, "compaction")?)?.contains_key("reserveTokens") {
        object(child(settings, "compaction")?)?.insert("reserveTokens".into(), json!(40000));
    }
    Ok(())
}

struct Change {
    path: PathBuf,
    old: Option<Vec<u8>>,
    data: Vec<u8>,
}
#[derive(Clone, Copy)]
enum DocFormat {
    Json,
    Yaml,
}
fn serialize(value: &Value, format: DocFormat) -> Result<Vec<u8>> {
    let mut data = match format {
        DocFormat::Json => serde_json::to_vec_pretty(value).context("Cannot serialize configuration")?,
        DocFormat::Yaml => serde_yaml::to_string(value)
            .context("Cannot serialize configuration")?
            .into_bytes(),
    };
    if !data.ends_with(b"\n") {
        data.push(b'\n');
    }
    Ok(data)
}
fn stage(path: PathBuf, before: Value, after: Value, format: DocFormat) -> Result<Option<Change>> {
    check_path(&path)?;
    if before == after && path.exists() {
        return Ok(None);
    }
    let old = match fs::read(&path) {
        Ok(data) => Some(data),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(_) => bail!("Cannot read existing configuration"),
    };
    Ok(Some(Change {
        path,
        old,
        data: serialize(&after, format)?,
    }))
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

struct Target {
    path: PathBuf,
    format: DocFormat,
}
fn existing_targets(
    dir: &Path,
    names: &[(&str, DocFormat)],
    default_name: &str,
    default_format: DocFormat,
) -> Vec<Target> {
    let found: Vec<Target> = names
        .iter()
        .filter_map(|(name, format)| {
            let path = dir.join(name);
            path.exists().then_some(Target { path, format: *format })
        })
        .collect();
    if found.is_empty() {
        vec![Target {
            path: dir.join(default_name),
            format: default_format,
        }]
    } else {
        found
    }
}
fn model_targets(dir: &Path) -> Vec<Target> {
    existing_targets(
        dir,
        &[
            ("models.yml", DocFormat::Yaml),
            ("models.yaml", DocFormat::Yaml),
            ("models.json", DocFormat::Json),
        ],
        "models.yml",
        DocFormat::Yaml,
    )
}
fn omp_setting_targets(dir: &Path) -> Vec<Target> {
    existing_targets(
        dir,
        &[
            ("config.yml", DocFormat::Yaml),
            ("config.yaml", DocFormat::Yaml),
            ("settings.json", DocFormat::Json),
        ],
        "config.yml",
        DocFormat::Yaml,
    )
}
fn stage_models(target: &Target, config: &ModelConfig, endpoint: &str) -> Result<(Option<Change>, HashSet<String>)> {
    let before = read_doc(&target.path, target.format)?;
    let mut after = before.clone();
    let removed = replace_models(&mut after, config, endpoint)?;
    Ok((stage(target.path.clone(), before, after, target.format)?, removed))
}

/// Replace custom model providers in Pi and Oh My Pi. Never contacts the endpoint.
/// All documents are parsed and validated before any configuration is replaced.
pub fn configure(config: &ModelConfig, pi_dir: &Path, omp_dir: &Path) -> Result<()> {
    let endpoint = base_url(config)?;
    check_path(pi_dir)?;
    check_path(omp_dir)?;
    let mut changes = Vec::new();
    let mut removed = HashSet::new();
    for target in [
        Target {
            path: pi_dir.join("models.json"),
            format: DocFormat::Json,
        },
    ]
    .into_iter()
    .chain(model_targets(omp_dir))
    {
        let (change, refs) = stage_models(&target, config, &endpoint)?;
        removed.extend(refs);
        if let Some(change) = change {
            changes.push(change);
        }
    }
    let pi_settings = pi_dir.join("settings.json");
    let before = read(&pi_settings)?;
    let mut after = before.clone();
    object(&mut after)?.insert("defaultProvider".into(), json!(PROVIDER));
    object(&mut after)?.insert("defaultModel".into(), json!(config.model_id));
    object(&mut after)?.insert("defaultThinkingLevel".into(), json!("medium"));
    object(child(&mut after, "thinkingBudgets")?)?.insert("medium".into(), json!(8192));
    object(child(&mut after, "compaction")?)?.insert("reserveTokens".into(), json!(40000));
    if let Some(change) = stage(pi_settings, before, after, DocFormat::Json)? {
        changes.push(change);
    }
    for target in omp_setting_targets(omp_dir) {
        let before = read_doc(&target.path, target.format)?;
        let mut after = before.clone();
        retarget_settings(&mut after, config, &removed)?;
        if let Some(change) = stage(target.path, before, after, target.format)? {
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
    let mut harden = vec![pi_dir.join("models.json"), pi_dir.join("settings.json")];
    harden.extend(model_targets(omp_dir).into_iter().map(|target| target.path));
    harden.extend(omp_setting_targets(omp_dir).into_iter().map(|target| target.path));
    for path in harden {
        if path.is_file() {
            private(&path, false)?;
        }
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
            read(&pi.join("settings.json")).unwrap()["defaultModel"],
            DEFAULT_MODEL
        );
        let pm = read(&pi.join("models.json")).unwrap();
        assert_eq!(
            pm["providers"][PROVIDER]["baseUrl"],
            "https://example.invalid/v1"
        );
        assert_eq!(
            pm["providers"][PROVIDER]["models"][0]["contextWindow"],
            200000
        );
        assert_eq!(
            pm["providers"][PROVIDER]["models"][0]["input"],
            json!(["text", "image"])
        );
        assert_eq!(pm["providers"].as_object().unwrap().len(), 1);
        let omp_models = read_doc(&omp.join("models.yml"), DocFormat::Yaml).unwrap();
        assert_eq!(
            omp_models["providers"][PROVIDER]["models"][0]["input"],
            json!(["text", "image"])
        );
        let omp_config = read_doc(&omp.join("config.yml"), DocFormat::Yaml).unwrap();
        assert_eq!(
            omp_config["modelRoles"]["vision"],
            format!("{PROVIDER}/{DEFAULT_MODEL}")
        );
        assert_eq!(omp_config["defaultThinkingLevel"], "medium");
        let pc = &pm["providers"][PROVIDER]["models"][0]["compat"];
        assert_eq!(pc["thinkingTokenBudgetField"], "thinking_token_budget");
        assert_eq!(
            pc["chatTemplateKwargs"]["reasoning_effort"]["$var"],
            "thinking.effort"
        );
        let settings = read(&pi.join("settings.json")).unwrap();
        assert_eq!(settings["defaultThinkingLevel"], "medium");
        assert_eq!(settings["thinkingBudgets"]["medium"], 8192);
        assert_eq!(settings["compaction"]["reserveTokens"], 40000);
        configure(&config(), &pi, &omp).unwrap();
        assert!(!pi.join("models.json.bak").exists());
        assert!(!omp.join("models.yml.bak").exists());
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
        directory(&pi).unwrap();
        let original = br#"{"theme":"dark","custom":{"a":1}}"#;
        fs::write(pi.join("settings.json"), original).unwrap();
        fs::write(pi.join("auth.json"), "opaque unchanged bytes").unwrap();
        fs::write(
            pi.join("models.json"),
            r#"{"providers":{"other":{"apiKey":"keep","models":[{"id":"retired"}]}}}"#,
        )
        .unwrap();
        let omp = tmp.path().join("omp");
        configure(&config(), &pi, &omp).unwrap();
        assert_eq!(fs::read(pi.join("settings.json.bak")).unwrap(), original);
        assert_eq!(read(&pi.join("settings.json")).unwrap()["custom"]["a"], 1);
        let models = read(&pi.join("models.json")).unwrap();
        assert!(models["providers"].get("other").is_none());
        assert_eq!(models["providers"][PROVIDER]["models"][0]["id"], DEFAULT_MODEL);
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
            directory(&pi).unwrap();
            fs::write(pi.join("models.json"), bad).unwrap();
            assert!(configure(&config(), &pi, &tmp.path().join("omp")).is_err());
            assert_eq!(fs::read_to_string(pi.join("models.json")).unwrap(), bad);
        }
    }
    #[test]
    fn validates_all_documents_before_replacing_any() {
        let tmp = scratch();
        let pi = tmp.path().join("pi");
        directory(&pi).unwrap();
        fs::write(pi.join("models.json"), "{}").unwrap();
        fs::write(pi.join("settings.json"), "{\"compaction\":[]}").unwrap();
        let omp = tmp.path().join("omp");
        assert!(configure(&config(), &pi, &omp).is_err());
        assert!(!omp.exists());
        assert_eq!(fs::read_to_string(pi.join("models.json")).unwrap(), "{}");
        assert_eq!(
            fs::read_to_string(pi.join("settings.json")).unwrap(),
            "{\"compaction\":[]}"
        );
        assert!(!pi.join("models.json.bak").exists());
    }
    #[test]
    fn removes_old_models_and_points_vision_at_the_current_model() {
        let tmp = scratch();
        let pi = tmp.path().join("pi");
        let omp = tmp.path().join("omp");
        directory(&pi).unwrap();
        directory(&omp).unwrap();
        fs::write(
            omp.join("models.yml"),
            "providers:\n  hotschmoe:\n    models:\n      - id: retired-model\n        input: [text]\n  hotschmoe-local:\n    models:\n      - id: hotschmoe-dd\n        input: [text]\n",
        )
        .unwrap();
        fs::write(
            omp.join("config.yml"),
            "display: kept\nenabledModels:\n  - retired-model\ndisabledModels:\n  - hotschmoe-dd\nmodelRoles:\n  default: hotschmoe-local/retired-model\n  plan: retired-model:high\n  slow: anthropic/claude-sonnet\n",
        )
        .unwrap();
        configure(&config(), &pi, &omp).unwrap();
        let models = read_doc(&omp.join("models.yml"), DocFormat::Yaml).unwrap();
        assert!(models["providers"].get("hotschmoe").is_none());
        assert_eq!(
            models["providers"][PROVIDER]["models"][0]["input"],
            json!(["text", "image"])
        );
        let settings = read_doc(&omp.join("config.yml"), DocFormat::Yaml).unwrap();
        assert_eq!(settings["display"], "kept");
        assert_eq!(settings["enabledModels"], json!(["hotschmoe-dd"]));
        assert_eq!(settings["disabledModels"], json!([]));
        assert_eq!(
            settings["modelRoles"]["vision"],
            "hotschmoe-local/hotschmoe-dd"
        );
        assert_eq!(
            settings["modelRoles"]["plan"],
            "hotschmoe-local/hotschmoe-dd:high"
        );
        assert_eq!(settings["modelRoles"]["slow"], "anthropic/claude-sonnet");
        configure(&config(), &pi, &omp).unwrap();
        assert!(!omp.join("config.yml.bak.1").exists());
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
        directory(&pi).unwrap();
        let target = tmp.path().join("target");
        fs::write(&target, "{}").unwrap();
        symlink(&target, pi.join("models.json")).unwrap();
        assert!(configure(&config(), &pi, &tmp.path().join("omp")).is_err());
        assert_eq!(fs::read_to_string(target).unwrap(), "{}");
        let alias = tmp.path().join("alias");
        symlink(&pi, &alias).unwrap();
        assert!(configure(&config(), &alias, &tmp.path().join("omp")).is_err());
    }
}

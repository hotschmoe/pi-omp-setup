use std::{
    fs,
    path::Path,
    process::{Command, Output},
};

const PASSWORD: &str = "dummy-only-six-word-fixture-passphrase";
const API_KEY: &str = "dummy-api-key-never-real";

fn run(args: &[&str], cwd: &Path) -> Output {
    let output = Command::new(env!("CARGO_BIN_EXE_pi-omp-setup"))
        .args(args)
        .current_dir(cwd)
        .output()
        .unwrap();
    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!combined.contains(PASSWORD));
    assert!(!combined.contains(API_KEY));
    assert!(!combined.contains("https://example.invalid"));
    output
}

#[test]
fn encrypted_cli_roundtrip_wrong_password_and_preservation() {
    // macOS temporary paths commonly traverse the system /var symlink.
    let tmp = tempfile::tempdir_in(fs::canonicalize(std::env::temp_dir()).unwrap()).unwrap();
    let root = tmp.path();
    fs::write(
        root.join("input.json"),
        format!(r#"{{"endpoint":"https://example.invalid","api_key":"{API_KEY}"}}"#),
    )
    .unwrap();
    fs::write(root.join("password.txt"), PASSWORD).unwrap();
    fs::write(root.join("wrong.txt"), "wrong-test-only-password").unwrap();
    assert!(run(
        &[
            "seal",
            "--input",
            "input.json",
            "--output",
            "bundle.json",
            "--password-file",
            "password.txt"
        ],
        root
    )
    .status
    .success());
    let bundle = fs::read_to_string(root.join("bundle.json")).unwrap();
    assert!(!bundle.contains(API_KEY));
    assert!(!bundle.contains("example.invalid"));
    assert!(run(
        &[
            "check",
            "--bundle",
            "bundle.json",
            "--password-file",
            "password.txt"
        ],
        root
    )
    .status
    .success());
    let wrong = run(
        &[
            "configure",
            "--bundle",
            "bundle.json",
            "--password-file",
            "wrong.txt",
            "--pi-dir",
            "pi",
            "--omp-dir",
            "omp",
        ],
        root,
    );
    assert!(!wrong.status.success());
    assert!(String::from_utf8_lossy(&wrong.stderr).contains("Incorrect passphrase"));
    assert!(!root.join("pi").exists());
    assert!(!root.join("omp").exists());
    fs::create_dir(root.join("pi")).unwrap();
    let settings = br#"{"theme":"existing-theme","unrelated":true}"#;
    fs::write(root.join("pi/settings.json"), settings).unwrap();
    let args = [
        "configure",
        "--bundle",
        "bundle.json",
        "--password-file",
        "password.txt",
        "--pi-dir",
        "pi",
        "--omp-dir",
        "omp",
    ];
    let configured = run(&args, root);
    assert!(
        configured.status.success(),
        "{}",
        String::from_utf8_lossy(&configured.stderr)
    );
    let pi: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("pi/models.json")).unwrap()).unwrap();
    assert_eq!(pi["providers"]["hotschmoe-local"]["apiKey"], API_KEY);
    assert_eq!(
        pi["providers"]["hotschmoe-local"]["models"][0]["id"],
        "hotschmoe-dd"
    );
    assert_eq!(
        fs::read(root.join("pi/settings.json.bak")).unwrap(),
        settings
    );
    let omp: serde_json::Value =
        serde_yaml_ng::from_slice(&fs::read(root.join("omp/config.yml")).unwrap()).unwrap();
    assert_eq!(omp["modelRoles"]["default"], "hotschmoe-local/hotschmoe-dd");
    assert!(run(&args, root).status.success());
    assert!(!root.join("pi/settings.json.bak.1").exists());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        for path in [
            "bundle.json",
            "pi/models.json",
            "pi/settings.json.bak",
            "omp/models.yml",
        ] {
            assert_eq!(
                fs::metadata(root.join(path)).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }
    #[cfg(windows)]
    {
        // Ask Windows for the actual DACL instead of matching localized icacls text.
        let checked = Command::new("powershell.exe").args(["-NoProfile", "-NonInteractive", "-Command",
            "$ErrorActionPreference='Stop'; $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value; foreach ($p in @('bundle.json','pi/models.json','pi/settings.json.bak','omp/models.yml')) { $acl=[IO.File]::GetAccessControl([IO.Path]::GetFullPath($p)); if (-not $acl.AreAccessRulesProtected) { throw 'Inherited ACL remained' }; foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) { if ($rule.IdentityReference.Value -ne $sid) { throw ('Unexpected ACL principal for {0}: {1}, expected {2}' -f $p,$rule.IdentityReference.Value,$sid) } } }"
        ]).current_dir(root).output().unwrap();
        assert!(
            checked.status.success(),
            "{}",
            String::from_utf8_lossy(&checked.stderr)
        );
    }
}

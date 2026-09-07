mod config;
mod vault;

use anyhow::{bail, Context, Result};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use clap::{Parser, Subcommand};
use rand::{rngs::OsRng, RngCore};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};
use zeroize::Zeroizing;

#[derive(Parser)]
#[command(
    version,
    about = "Install private model settings without publishing credentials"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Decrypt a deployment bundle and merge it into Pi and OMP user settings.
    Configure {
        #[arg(long)]
        bundle: PathBuf,
        #[arg(long)]
        pi_dir: Option<PathBuf>,
        #[arg(long)]
        omp_dir: Option<PathBuf>,
        #[arg(long)]
        password_file: Option<PathBuf>,
    },
    /// Verify a deployment bundle without writing any client settings.
    Check {
        #[arg(long)]
        bundle: PathBuf,
        #[arg(long)]
        password_file: Option<PathBuf>,
    },
    /// Maintainer command: encrypt a private JSON configuration for distribution.
    Seal {
        #[arg(long)]
        input: PathBuf,
        #[arg(long)]
        output: PathBuf,
        #[arg(long, conflicts_with = "generate_passphrase")]
        password_file: Option<PathBuf>,
        /// Write a generated 256-bit passphrase to a new private local file.
        #[arg(long, conflicts_with = "password_file")]
        generate_passphrase: Option<PathBuf>,
    },
}

fn read_limited(path: &Path, limit: u64) -> Result<Zeroizing<Vec<u8>>> {
    use std::io::Read;
    let mut data = Zeroizing::new(Vec::new());
    fs::File::open(path)
        .context("Cannot open input file")?
        .take(limit + 1)
        .read_to_end(&mut data)
        .context("Cannot read input file")?;
    if data.len() as u64 > limit {
        bail!("Input file exceeds size limit");
    }
    Ok(data)
}

fn password(path: Option<&Path>) -> Result<Zeroizing<String>> {
    let value = if let Some(path) = path {
        let bytes = read_limited(path, 4096)?;
        String::from_utf8(bytes.to_vec())
            .context("Passphrase file is not UTF-8")?
            .trim_end_matches(['\r', '\n'])
            .to_string()
    } else {
        rpassword::prompt_password("Setup passphrase: ")
            .context("Cannot read passphrase; use an interactive terminal")?
    };
    if value.is_empty() {
        bail!("Passphrase cannot be empty");
    }
    Ok(Zeroizing::new(value))
}

fn parse_config(bytes: &[u8]) -> Result<config::ModelConfig> {
    let config = serde_json::from_slice(bytes).map_err(|_| {
        anyhow::anyhow!("Decrypted configuration is not a valid model configuration")
    })?;
    config::validate(&config)?;
    Ok(config)
}

fn write_new_private(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(path)
        .context("Cannot create new output file (it may already exist)")?;
    #[cfg(windows)]
    {
        // Protect the empty file before writing any bytes, using the same
        // exact current-user DACL as client configuration files.
        config::private(path, false)?;
    }
    file.write_all(bytes).context("Cannot write output file")?;
    file.sync_all().context("Cannot sync output file")?;
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        // Errors never include decrypted configuration or the passphrase.
        eprintln!("Setup failed: {error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    match Cli::parse().command {
        Commands::Configure {
            bundle,
            pi_dir,
            omp_dir,
            password_file,
        } => {
            let password = password(password_file.as_deref())?;
            let bundle = read_limited(&bundle, 64 * 1024)?;
            let plaintext = vault::open(&bundle, password.as_bytes())?;
            let config = parse_config(&plaintext)?;
            let home = dirs::home_dir().context("Cannot determine home directory")?;
            let home = fs::canonicalize(home).context("Cannot resolve home directory")?;
            let pi_dir = pi_dir.unwrap_or_else(|| home.join(".pi/agent"));
            let omp_dir = omp_dir.unwrap_or_else(|| home.join(".omp/agent"));
            config::configure(&config, &pi_dir, &omp_dir)?;
            println!("Pi and OMP model configuration installed. Credentials were not printed.");
        }
        Commands::Check {
            bundle,
            password_file,
        } => {
            let password = password(password_file.as_deref())?;
            let bundle = read_limited(&bundle, 64 * 1024)?;
            let plaintext = vault::open(&bundle, password.as_bytes())?;
            let _ = parse_config(&plaintext)?;
            println!("Encrypted configuration verified.");
        }
        Commands::Seal {
            input,
            output,
            password_file,
            generate_passphrase,
        } => {
            let plaintext = read_limited(&input, 32 * 1024)?;
            let _ = parse_config(&plaintext)?;
            let password = if let Some(path) = generate_passphrase {
                let mut random = Zeroizing::new([0u8; 32]);
                OsRng.fill_bytes(&mut *random);
                let password = Zeroizing::new(URL_SAFE_NO_PAD.encode(random.as_slice()));
                write_new_private(&path, password.as_bytes())?;
                println!("Generated passphrase saved to the private file you specified.");
                password
            } else {
                let password = password(password_file.as_deref())?;
                if password_file.is_none() {
                    let confirmation =
                        Zeroizing::new(rpassword::prompt_password("Confirm passphrase: ")?);
                    if *password != *confirmation {
                        bail!("Passphrases do not match");
                    }
                }
                password
            };
            let encrypted = vault::seal(&plaintext, password.as_bytes())?;
            write_new_private(&output, &encrypted)?;
            println!("Encrypted deployment bundle created. Keep the passphrase outside Git.");
        }
    }
    Ok(())
}

use aes_gcm::{aead::Aead, aead::Payload, Aes256Gcm, KeyInit, Nonce};
use anyhow::{bail, Context, Result};
use argon2::{Algorithm, Argon2, Params, Version};
use base64::{engine::general_purpose::STANDARD, Engine};
use rand::{rngs::OsRng, RngCore};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

const AAD: &[u8] = b"pi-omp-setup/config/v1";
const MAX_BUNDLE_BYTES: usize = 64 * 1024;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Envelope {
    format: String,
    kdf: String,
    memory_kib: u32,
    iterations: u32,
    parallelism: u32,
    salt: String,
    nonce: String,
    ciphertext: String,
}

fn key(password: &[u8], salt: &[u8]) -> Result<Zeroizing<[u8; 32]>> {
    let params = Params::new(65_536, 3, 1, Some(32))
        .map_err(|_| anyhow::anyhow!("Invalid KDF parameters"))?;
    let argon = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut key = Zeroizing::new([0u8; 32]);
    argon
        .hash_password_into(password, salt, &mut *key)
        .map_err(|_| anyhow::anyhow!("Password derivation failed"))?;
    Ok(key)
}

pub fn seal(plaintext: &[u8], password: &[u8]) -> Result<Vec<u8>> {
    if plaintext.len() > MAX_BUNDLE_BYTES / 2 || password.is_empty() {
        bail!("Configuration is too large or passphrase is empty");
    }
    let mut salt = [0u8; 16];
    let mut nonce = [0u8; 12];
    OsRng.fill_bytes(&mut salt);
    OsRng.fill_bytes(&mut nonce);
    let key = key(password, &salt)?;
    let cipher =
        Aes256Gcm::new_from_slice(&*key).map_err(|_| anyhow::anyhow!("Cipher setup failed"))?;
    let ciphertext = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad: AAD,
            },
        )
        .map_err(|_| anyhow::anyhow!("Configuration encryption failed"))?;
    Ok(serde_json::to_vec_pretty(&Envelope {
        format: "pi-omp-setup-v1".into(),
        kdf: "argon2id-v19".into(),
        memory_kib: 65_536,
        iterations: 3,
        parallelism: 1,
        salt: STANDARD.encode(salt),
        nonce: STANDARD.encode(nonce),
        ciphertext: STANDARD.encode(ciphertext),
    })?)
}

pub fn open(bundle: &[u8], password: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    if bundle.len() > MAX_BUNDLE_BYTES || password.is_empty() {
        bail!("Invalid bundle size or empty passphrase");
    }
    let envelope: Envelope = serde_json::from_slice(bundle)
        .map_err(|_| anyhow::anyhow!("Invalid encrypted configuration format"))?;
    // Fixed parameters prevent a modified public bundle from requesting
    // unbounded memory/work, or silently weakening password derivation.
    if envelope.format != "pi-omp-setup-v1"
        || envelope.kdf != "argon2id-v19"
        || envelope.memory_kib != 65_536
        || envelope.iterations != 3
        || envelope.parallelism != 1
    {
        bail!("Unsupported encrypted configuration format or KDF parameters");
    }
    let salt = STANDARD
        .decode(envelope.salt)
        .context("Invalid salt encoding")?;
    let nonce = STANDARD
        .decode(envelope.nonce)
        .context("Invalid nonce encoding")?;
    let ciphertext = STANDARD
        .decode(envelope.ciphertext)
        .context("Invalid ciphertext encoding")?;
    if salt.len() != 16 || nonce.len() != 12 || ciphertext.len() < 16 {
        bail!("Invalid encrypted configuration lengths");
    }
    let key = key(password, &salt)?;
    let cipher =
        Aes256Gcm::new_from_slice(&*key).map_err(|_| anyhow::anyhow!("Cipher setup failed"))?;
    let plaintext = cipher
        .decrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: &ciphertext,
                aad: AAD,
            },
        )
        .map_err(|_| anyhow::anyhow!("Incorrect passphrase or damaged encrypted configuration"))?;
    Ok(Zeroizing::new(plaintext))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_randomized_and_authenticated() {
        let plaintext = br#"{"endpoint":"https://example.invalid/v1","api_key":"test-key","model_id":"hotschmoe-dd"}"#;
        let passphrase = b"a-long-test-only-passphrase";
        let first = seal(plaintext, passphrase).unwrap();
        let second = seal(plaintext, passphrase).unwrap();
        assert_ne!(first, second);
        assert!(!String::from_utf8_lossy(&first).contains("example.invalid"));
        assert!(!String::from_utf8_lossy(&first).contains("test-key"));
        assert_eq!(&**open(&first, passphrase).unwrap(), plaintext);
        assert!(open(&first, b"wrong-password").is_err());
        let mut envelope: serde_json::Value = serde_json::from_slice(&first).unwrap();
        let mut ciphertext = STANDARD
            .decode(envelope["ciphertext"].as_str().unwrap())
            .unwrap();
        ciphertext[0] ^= 1;
        envelope["ciphertext"] = STANDARD.encode(ciphertext).into();
        assert!(open(&serde_json::to_vec(&envelope).unwrap(), passphrase).is_err());
    }

    #[test]
    fn rejects_invalid_sizes_and_kdf_without_doing_work() {
        assert!(open(&vec![0; MAX_BUNDLE_BYTES + 1], b"test").is_err());
        assert!(open(b"{}", b"test").is_err());
        assert!(seal(b"test", b"").is_err());
        let mut envelope: serde_json::Value =
            serde_json::from_slice(&seal(b"test", b"test").unwrap()).unwrap();
        envelope["memory_kib"] = u32::MAX.into();
        assert!(open(&serde_json::to_vec(&envelope).unwrap(), b"test").is_err());
    }
}

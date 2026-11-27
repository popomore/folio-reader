use folio_core::{FileKind, Revision, Workspace};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    ffi::{CStr, CString, c_char},
    path::Path,
};

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum Request {
    FileKind {
        name: String,
    },
    RenderTextPreview {
        name: String,
        source: String,
    },
    HighlightSource {
        name: String,
        source: String,
    },
    List {
        root: String,
        path: String,
    },
    Read {
        root: String,
        path: String,
    },
    Save {
        root: String,
        path: String,
        revision: Revision,
        source: String,
    },
    #[cfg(feature = "git")]
    Git {
        root: String,
        path: String,
    },
    #[cfg(feature = "git")]
    Changes {
        root: String,
        path: String,
    },
    #[cfg(feature = "git")]
    Patch {
        root: String,
        path: String,
        commit: Option<String>,
    },
}

impl Request {
    fn run(self) -> Result<Value, folio_core::Error> {
        Ok(match self {
            Self::FileKind { name } => json!(FileKind::from_path(Path::new(&name))),
            Self::RenderTextPreview { name, source } => {
                json!(folio_core::render_text_preview(Path::new(&name), &source)?)
            }
            Self::HighlightSource { name, source } => {
                json!(folio_core::highlight_source(Path::new(&name), &source))
            }
            Self::List { root, path } => json!(Workspace::open(root)?.list(path)?),
            Self::Read { root, path } => json!(Workspace::open(root)?.read(path)?),
            Self::Save {
                root,
                path,
                revision,
                source,
            } => json!(Workspace::open(root)?.save(path, &revision, &source)?),
            #[cfg(feature = "git")]
            Self::Git { root, path } => json!(Workspace::open(root)?.git_file(path)?),
            #[cfg(feature = "git")]
            Self::Changes { root, path } => json!(Workspace::open(root)?.git_changes(path)?),
            #[cfg(feature = "git")]
            Self::Patch { root, path, commit } => {
                json!(Workspace::open(root)?.git_patch(path, commit.as_deref())?)
            }
        })
    }
}

/// # Safety
/// request must be a non-null pointer to a NUL-terminated string valid for this call.
/// The result must be released exactly once with folio_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn folio_call(request: *const c_char) -> *mut c_char {
    let response = std::panic::catch_unwind(|| {
        let request = unsafe { CStr::from_ptr(request) };
        match serde_json::from_slice::<Request>(request.to_bytes()) {
            Ok(request) => match request.run() {
                Ok(value) => json!({ "value": value }),
                Err(error) => json!({ "error": error.to_string() }),
            },
            Err(error) => json!({ "error": error.to_string() }),
        }
    })
    .unwrap_or_else(|_| json!({ "error": "The reader could not complete that operation." }));
    CString::new(response.to_string())
        .expect("JSON escapes NUL bytes")
        .into_raw()
}

/// # Safety
/// result must be null or a live pointer returned by folio_call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn folio_free(result: *mut c_char) {
    if !result.is_null() {
        drop(unsafe { CString::from_raw(result) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(body: Value) -> Value {
        let request = CString::new(body.to_string()).unwrap();
        // SAFETY: the request lives through the call and the result is freed once.
        unsafe {
            let result = folio_call(request.as_ptr());
            let response = serde_json::from_slice(CStr::from_ptr(result).to_bytes()).unwrap();
            folio_free(result);
            response
        }
    }

    #[test]
    fn bridge_reads_saves_and_rejects_a_stale_revision() {
        let root = tempfile::tempdir().unwrap();
        let file = root.path().join("note.md");
        std::fs::write(&file, "# Original\n").unwrap();
        let document = call(json!({"op": "read", "root": root.path(), "path": "note.md"}));
        assert_eq!(document["value"]["kind"], "markdown");
        let revision = document["value"]["revision"].clone();
        let saved = call(json!({
            "op": "save", "root": root.path(), "path": "note.md",
            "revision": revision, "source": "# Saved\n"
        }));
        assert!(saved["value"].is_string());
        let conflict = call(json!({
            "op": "save", "root": root.path(), "path": "note.md",
            "revision": revision, "source": "Do not overwrite"
        }));
        assert!(
            conflict["error"]
                .as_str()
                .unwrap()
                .contains("changed on disk")
        );
        assert_eq!(std::fs::read_to_string(file).unwrap(), "# Saved\n");
    }

    #[cfg(not(feature = "git"))]
    #[test]
    fn git_operations_are_not_exposed_by_the_mobile_bridge() {
        for op in ["git", "changes", "patch"] {
            assert!(call(json!({"op": op, "root": "/", "path": ""}))["error"].is_string());
        }
    }
}

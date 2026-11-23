use folio_core::{Error, FileKind, Workspace, render_markdown, sanitize_html};
use std::{fs, path::Path};
use tempfile::tempdir;

#[test]
fn rich_preview_is_readable_and_escapes_author_html() {
    let preview = render_markdown(
        "# 中文 标题\n\n# 中文 标题\n\n- [x] Checked\n\n![test](image.png)\n\n<iframe src=\"x\"></iframe>",
    );
    assert_eq!(preview.headings[0].id, "中文-标题");
    assert_eq!(preview.headings[1].id, "中文-标题-1");
    assert!(preview.html.contains("disabled"));
    assert!(preview.html.contains("checked"));
    assert!(preview.html.contains("image.png"));
    assert!(!preview.html.contains("<iframe"));
    let html = sanitize_html(
        "<p onclick='doBad()'>text</p><script>bad()</script><a href='javascript:bad()'>link</a>",
    );
    for removed in ["onclick", "script", "bad()"] {
        assert!(!html.contains(removed));
    }
}

#[test]
fn save_preserves_text_format_and_detects_conflicts() -> Result<(), Error> {
    let root = tempdir()?;
    let file = root.path().join("note.md");
    fs::write(&file, b"\xef\xbb\xbf# Note\r\nOriginal\r\n")?;
    let workspace = Workspace::open(root.path())?;
    let original = workspace.read("note.md")?.revision.unwrap();
    let updated = workspace.save("note.md", &original, "# Change\nUpdated\n")?;
    assert_eq!(fs::read(&file)?, b"\xef\xbb\xbf# Change\r\nUpdated\r\n");
    fs::write(&file, b"Changed elsewhere")?;
    assert!(matches!(
        workspace.save("note.md", &updated, "draft"),
        Err(Error::Conflict)
    ));
    assert_eq!(fs::read(file)?, b"Changed elsewhere");
    Ok(())
}

#[cfg(unix)]
#[test]
fn save_conflicts_with_a_locked_file() -> Result<(), Error> {
    let root = tempdir()?;
    let path = root.path().join("note.md");
    fs::write(&path, "# Original")?;
    let workspace = Workspace::open(root.path())?;
    let revision = workspace.read("note.md")?.revision.unwrap();
    let writer = fs::OpenOptions::new().read(true).write(true).open(&path)?;
    writer.lock()?;
    assert!(matches!(
        workspace.save("note.md", &revision, "# Draft"),
        Err(Error::Conflict)
    ));
    assert_eq!(fs::read_to_string(&path)?, "# Original");
    // A concurrently spawned child can briefly inherit the descriptor on Unix.
    writer.unlock()?;
    workspace.save("note.md", &revision, "# Draft")?;
    assert_eq!(fs::read_to_string(path)?, "# Draft");
    Ok(())
}

#[test]
fn file_selection_respects_scope_and_format() -> Result<(), Error> {
    let root = tempdir()?;
    let workspace = Workspace::open(root.path())?;
    fs::create_dir(root.path().join("notes"))?;
    fs::write(
        root.path().join("sample.csv"),
        "Title,Value\n\"Name\twith tab\",<script>",
    )?;
    fs::write(root.path().join(".hidden"), "Invisible")?;
    let entries = workspace.list("")?;
    assert_eq!(entries.len(), 2);
    assert!(entries[0].directory);
    let table = workspace.read("sample.csv")?;
    assert_eq!(table.kind, FileKind::Table);
    assert!(table.preview.unwrap().html.contains("&lt;script&gt;"));
    assert!(table.revision.is_none());
    assert!(matches!(
        workspace.read("../outside.md"),
        Err(Error::OutsideWorkspace)
    ));
    assert!(matches!(
        workspace.read(Path::new("/etc/hosts")),
        Err(Error::OutsideWorkspace)
    ));
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink("/etc/hosts", root.path().join("external"))?;
        assert!(matches!(
            workspace.read("external"),
            Err(Error::OutsideWorkspace)
        ));
    }
    Ok(())
}

#[test]
fn svg_files_are_read_only_images() -> Result<(), Error> {
    let root = tempdir()?;
    let svg = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"><rect width="1" height="1"/></svg>"#;
    fs::write(root.path().join("diagram.SVG"), svg)?;
    let document = Workspace::open(root.path())?.read("diagram.SVG")?;
    assert_eq!(document.kind, FileKind::Image);
    assert_eq!(document.bytes, svg.len() as u64);
    assert!(document.source.is_none() && document.revision.is_none() && document.preview.is_none());
    Ok(())
}

#[test]
fn models_are_read_only_even_when_the_format_is_text() -> Result<(), Error> {
    let root = tempdir()?;
    let workspace = Workspace::open(root.path())?;
    for name in [
        "part.STL",
        "part.obj",
        "scan.ply",
        "scene.gltf",
        "scene.glb",
        "print.3MF",
    ] {
        fs::write(root.path().join(name), b"model fixture\0")?;
        let document = workspace.read(name)?;
        assert_eq!(document.kind, FileKind::Model, "{name}");
        assert!(!document.kind.editable());
        assert_eq!(document.bytes, 14);
        assert!(
            document.source.is_none() && document.revision.is_none() && document.preview.is_none()
        );
    }
    assert!(
        workspace
            .list("")?
            .iter()
            .all(|entry| entry.kind == Some(FileKind::Model))
    );
    Ok(())
}

#[test]
fn archives_are_read_only_and_models_keep_their_preview_kind() -> Result<(), Error> {
    let root = tempdir()?;
    let workspace = Workspace::open(root.path())?;
    for name in [
        "notes.ZIP",
        "files.tar",
        "files.tar.gz",
        "files.tgz",
        "files.tar.bz2",
        "files.tbz",
        "files.tbz2",
        "files.tar.xz",
        "files.txz",
        "files.7z",
        "files.rar",
        "note.md.gz",
        "note.md.bz2",
        "note.md.xz",
    ] {
        fs::write(root.path().join(name), b"archive fixture\0")?;
        let document = workspace.read(name)?;
        assert_eq!(document.kind, FileKind::Archive, "{name}");
        assert!(!document.kind.editable());
        assert_eq!(document.bytes, 16);
        assert!(
            document.source.is_none() && document.revision.is_none() && document.preview.is_none()
        );
    }
    assert!(
        workspace
            .list("")?
            .iter()
            .all(|entry| entry.kind == Some(FileKind::Archive))
    );
    assert_eq!(
        FileKind::from_path(Path::new("project.gcode.3mf")),
        FileKind::Model
    );
    Ok(())
}

#[cfg(feature = "git")]
#[test]
fn file_history_and_staged_and_unstaged_patches() -> Result<(), Error> {
    let root = tempdir()?;
    let repo = git2::Repository::init(root.path())?;
    let file = root.path().join("name [with brackets].md");
    fs::write(&file, "# Original\n")?;
    let path = Path::new("name [with brackets].md");
    let mut index = repo.index()?;
    index.add_path(path)?;
    index.write()?;
    let tree = repo.find_tree(index.write_tree()?)?;
    let sig = git2::Signature::now("Folio QA", "local@example.invalid")?;
    let commit = repo.commit(Some("HEAD"), &sig, &sig, "Initial note", &tree, &[])?;
    fs::write(&file, "# Staged\n")?;
    index.add_path(path)?;
    index.write()?;
    fs::write(file, "# Working tree\n")?;
    let workspace = Workspace::open(root.path())?;
    let history = workspace.git_file(path)?.unwrap();
    assert_eq!(history.staged.as_deref(), Some("Modified"));
    assert_eq!(history.unstaged.as_deref(), Some("Modified"));
    assert_eq!(history.commits[0].id, commit.to_string());
    let patch = workspace.git_patch(path, None)?.unwrap();
    assert!(patch.text.contains("+# Staged"));
    assert!(patch.text.contains("+# Working tree"));
    let patch = workspace
        .git_patch(path, Some(&commit.to_string()))?
        .unwrap();
    assert!(patch.text.contains("+# Original"));
    Ok(())
}

#[cfg(target_os = "macos")]
#[test]
fn save_keeps_macos_extended_attributes() -> Result<(), Error> {
    use std::process::Command;
    let root = tempdir()?;
    let file = root.path().join("note.md");
    fs::write(&file, "# Original")?;
    let attr = "org.popomore.folio.test";
    assert!(
        Command::new("/usr/bin/xattr")
            .args(["-w", attr, "keep-me"])
            .arg(&file)
            .status()?
            .success()
    );
    let workspace = Workspace::open(root.path())?;
    workspace.save(
        "note.md",
        &workspace.read("note.md")?.revision.unwrap(),
        "# Revised",
    )?;
    let output = Command::new("/usr/bin/xattr")
        .args(["-p", attr])
        .arg(&file)
        .output()?;
    assert!(output.status.success());
    assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "keep-me");
    Ok(())
}

#[cfg(feature = "git")]
#[test]
fn git_changes_are_scoped_and_show_removed_file_patches() -> Result<(), Error> {
    let root = tempdir()?;
    let repo = git2::Repository::init(root.path())?;
    fs::create_dir(root.path().join("project"))?;
    fs::write(root.path().join("project/deleted.md"), "Previous content\n")?;
    fs::write(root.path().join("outside.md"), "Outside the workspace\n")?;
    let workspace = Workspace::open(root.path().join("project"))?;
    let initial = workspace.git_changes("")?.unwrap();
    assert_eq!(initial.total, 1);
    assert_eq!(initial.changes[0].unstaged.as_deref(), Some("Untracked"));

    let mut index = repo.index()?;
    let path = Path::new("project/deleted.md");
    index.add_path(path)?;
    index.write()?;
    let tree = repo.find_tree(index.write_tree()?)?;
    let sig = git2::Signature::now("Folio QA", "local@example.invalid")?;
    let id = repo.commit(Some("HEAD"), &sig, &sig, "Initial note", &tree, &[])?;
    fs::remove_file(root.path().join(path))?;

    let changes = workspace.git_changes("deleted.md")?.unwrap();
    assert_eq!(changes.total, 1);
    assert_eq!(changes.changes[0].path, "deleted.md");
    assert_eq!(changes.changes[0].unstaged.as_deref(), Some("Deleted"));
    assert!(
        workspace
            .git_patch("deleted.md", None)?
            .unwrap()
            .text
            .contains("-Previous content")
    );
    assert_eq!(
        workspace.git_file("deleted.md")?.unwrap().commits[0].id,
        id.to_string()
    );
    assert!(matches!(
        workspace.git_patch("../outside.md", None),
        Err(Error::OutsideWorkspace)
    ));
    Ok(())
}

use folio_core::{
    FileKind, SyntaxToken, Workspace, highlight_source, render_markdown, render_text_preview,
};
use std::path::Path;

const LINE_NUMBER: &str = "<span class=\"code-line-number\" aria-hidden=\"true\"></span>";

#[test]
fn source_preview_recognizes_common_languages_by_filename() {
    let samples = [
        ("Example.SWIFT", "let sample: Int = 42\n"),
        ("script.ts", "const sample: number = 42;\n"),
        (
            "component.tsx",
            "export const element = <div>Hello</div>;\n",
        ),
        ("example.rs", "fn main() { let sample = 42; }\n"),
        ("settings.toml", "sample = 42\n"),
        ("main.py", "def sample():\n    return 42\n"),
        ("config.json", "{\"sample\": 42}\n"),
        ("Makefile", "SHELL := /bin/sh\n"),
        ("Dockerfile", "FROM scratch\n"),
        (
            "CMakeLists.txt",
            "message(\"Folio sample\") # Build setup\n",
        ),
        ("MODULE.LUA", "local count = 42 -- Lua source\n"),
        ("main.rb", "def sample\n  42\nend\n"),
        ("page.php", "<?php return 42;\n"),
        (
            "Program.cs",
            "public class Program { public int Count = 42; }\n",
        ),
        ("main.dart", "const int count = 42;\n"),
        ("render.zig", "const count: u32 = 42;\n"),
        ("script.fish", "# Fish source\nset count 42\n"),
        ("Page.vue", "<template><p>Folio</p></template>\n"),
        (
            "Page.svelte",
            "<script>let count = 42;</script><p>{count}</p>\n",
        ),
        ("build.gradle.kts", "val count: Int = 42\n"),
        ("main.tf", "variable \"count\" { default = 42 }\n"),
    ];
    for (name, source) in samples {
        let preview = render_text_preview(Path::new(name), source)
            .unwrap()
            .unwrap();
        assert!(
            preview.html.contains("class=\"syntax "),
            "{name}: {}",
            preview.html
        );
        assert_eq!(
            preview.html.matches(LINE_NUMBER).count(),
            source.split('\n').count(),
            "{name}"
        );
    }
}

#[test]
fn matching_source_is_opened_as_an_editable_document() {
    let root = tempfile::tempdir().unwrap();
    let workspace = Workspace::open(root.path()).unwrap();
    std::fs::write(root.path().join("script.lua"), "local count = 42\n").unwrap();
    let document = workspace.read("script.lua").unwrap();
    assert_eq!(document.kind, FileKind::Text);
    assert!(document.revision.is_some());
    assert!(document.preview.unwrap().html.contains("syntax-keyword"));
    assert!(!highlight_source(Path::new("script.lua"), "local count = 42").is_empty());

    assert_eq!(
        FileKind::from_path(Path::new("diagram.svg")),
        FileKind::Image
    );
    assert_eq!(FileKind::from_path(Path::new("page.html")), FileKind::Html);
    assert_eq!(
        FileKind::from_path(Path::new("archive.zip")),
        FileKind::Archive
    );
}

#[test]
fn fenced_code_is_highlighted_without_interpreting_source_or_diagrams() {
    let preview = render_markdown(
        "# Example\n\n```rust info\nlet source = \"<script>&value</script>\";\n```\n\n\
         ```unknown-language\nlet source = 42;\n```\n\n\
         ```mermaid\nflowchart LR\nA-->B\n```\n\n    let plain = 42;\n",
    );
    let html = preview.html;
    assert!(html.contains("language-rust"));
    assert!(html.contains("<span class=\"syntax syntax-keyword\">let</span>"));
    assert!(html.contains("&lt;script&gt;&amp;value&lt;/script&gt;"));
    assert!(!html.contains("<script>"));
    assert!(html.contains(&format!(
        "<code class=\"language-unknown-language\">{LINE_NUMBER}let source = 42;"
    )));
    assert!(html.contains("<code class=\"language-mermaid\">flowchart LR"));
    assert!(html.contains(&format!("<code>{LINE_NUMBER}let plain = 42;")));
    assert_eq!(html.matches(LINE_NUMBER).count(), 3);
    assert_eq!(preview.headings[0].title, "Example");
}

#[test]
fn line_numbers_follow_blank_lines_and_multiline_colors_without_adding_text() {
    let source = "/* first\n\n  third */\n";
    let preview = render_text_preview(Path::new("example.rs"), source)
        .unwrap()
        .unwrap();
    let comment = "<span class=\"syntax syntax-comment\">";
    assert_eq!(preview.html.matches(LINE_NUMBER).count(), 4);
    assert!(
        preview
            .html
            .contains(&format!("</span>{LINE_NUMBER}{comment}\n</span>"))
    );
    assert_eq!(
        preview
            .html
            .replace(LINE_NUMBER, "")
            .replace(comment, "")
            .replace("</span>", ""),
        format!("<pre class=\"plain\"><code>{source}</code></pre>")
    );

    let mixed = render_text_preview(Path::new("demo.rs"), "first\r\n\r\nthird\rlast")
        .unwrap()
        .unwrap();
    assert_eq!(mixed.html.matches(LINE_NUMBER).count(), 4);
    let markdown = render_markdown("> ```\n> first\n>\n> third\n> ```");
    assert_eq!(markdown.html.matches(LINE_NUMBER).count(), 3);
}

#[test]
fn source_colors_use_utf16_offsets_and_keep_large_or_plain_buffers_readable() {
    let source = "let label = \"😀\"; let count = 42;\n";
    let spans = highlight_source(Path::new("demo.rs"), source);
    let start = source[..source.find("42").unwrap()].encode_utf16().count();
    assert!(spans.iter().any(|span| {
        span.token == SyntaxToken::Constant && span.start == start && span.end == start + 2
    }));
    assert!(highlight_source(Path::new("readme.txt"), source).is_empty());

    let large = "x".repeat(9_000);
    assert!(highlight_source(Path::new("demo.rs"), &large).is_empty());
    let preview = render_text_preview(Path::new("demo.rs"), &large)
        .unwrap()
        .unwrap();
    assert_eq!(
        preview.html,
        format!("<pre class=\"plain\"><code>{LINE_NUMBER}{large}</code></pre>")
    );
    let plain = render_text_preview(Path::new("readme.txt"), "first\nsecond")
        .unwrap()
        .unwrap();
    assert_eq!(plain.html, "<pre class=\"plain\">first\nsecond</pre>");
}

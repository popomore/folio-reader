use crate::{Error, syntax};
use pulldown_cmark::{CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd, html};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{collections::HashSet, path::Path};

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum FileKind {
    Markdown,
    Text,
    Html,
    Rtf,
    Pdf,
    Image,
    Audio,
    Video,
    Model,
    Archive,
    Table,
    Mermaid,
    Vega,
    Other,
}

impl FileKind {
    pub fn from_path(path: &Path) -> Self {
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        if name.ends_with(".vl.json") || name.ends_with(".vega-lite.json") {
            return Self::Vega;
        }
        match path
            .extension()
            .and_then(|ext| ext.to_str())
            .unwrap_or("")
            .to_ascii_lowercase()
            .as_str()
        {
            "md" | "markdown" | "mdown" | "mkd" => Self::Markdown,
            "html" | "htm" => Self::Html,
            "rtf" => Self::Rtf,
            "pdf" => Self::Pdf,
            "png" | "jpeg" | "jpg" | "gif" | "webp" | "heic" | "tif" | "tiff" | "bmp" | "avif"
            | "svg" => Self::Image,
            "mp3" | "m4a" | "aac" | "wav" | "aiff" | "caf" | "flac" => Self::Audio,
            "mp4" | "m4v" | "mov" => Self::Video,
            "stl" | "obj" | "ply" | "gltf" | "glb" | "3mf" => Self::Model,
            "zip" | "tar" | "gz" | "tgz" | "bz2" | "tbz" | "tbz2" | "xz" | "txz" | "7z" | "rar" => {
                Self::Archive
            }
            "csv" | "tsv" => Self::Table,
            "mmd" | "mermaid" => Self::Mermaid,
            "vl" => Self::Vega,
            "txt" | "text" | "log" | "json" | "jsonl" | "yaml" | "yml" | "xml" | "toml" | "ini"
            | "conf" | "rs" | "swift" | "c" | "h" | "cpp" | "hpp" | "py" | "js" | "ts" | "jsx"
            | "tsx" | "go" | "java" | "kt" | "sh" | "zsh" | "sql" | "css" | "scss" | "diff"
            | "patch" => Self::Text,
            "" if matches!(
                name.as_str(),
                "readme" | "license" | "makefile" | "dockerfile" | "changelog"
            ) =>
            {
                Self::Text
            }
            _ if syntax::for_file(path).is_some() => Self::Text,
            _ => Self::Other,
        }
    }

    pub fn editable(self) -> bool {
        matches!(self, Self::Markdown | Self::Text)
    }

    pub(crate) fn has_text(self) -> bool {
        matches!(
            self,
            Self::Markdown | Self::Text | Self::Html | Self::Table | Self::Mermaid | Self::Vega
        )
    }
}

/// Version of the exact bytes returned by read. Hosts pass it back to save.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Revision(String);

impl Revision {
    pub(crate) fn of(bytes: &[u8]) -> Self {
        Self(format!("{:x}", Sha256::digest(bytes)))
    }
}

#[derive(Debug, Serialize)]
pub struct Document {
    pub kind: FileKind,
    pub bytes: u64,
    pub source: Option<String>,
    pub revision: Option<Revision>,
    pub preview: Option<Preview>,
}

impl Document {
    pub(crate) fn new(kind: FileKind, bytes: u64) -> Self {
        Self {
            kind,
            bytes,
            source: None,
            revision: None,
            preview: None,
        }
    }

    pub(crate) fn load_text(&mut self, bytes: &[u8], path: &Path) -> Result<(), Error> {
        let (source, _) = decode_text(bytes)?;
        self.preview = text_preview(self.kind, path, source)?;
        self.source = self.kind.editable().then(|| source.to_owned());
        Ok(())
    }
}

/// Render already-authorized file contents without opening a directory or any
/// other file. Formats rendered by the host return `None`.
pub fn render_text_preview(path: &Path, source: &str) -> Result<Option<Preview>, Error> {
    let (source, _) = decode_text(source.as_bytes())?;
    text_preview(FileKind::from_path(path), path, source)
}

fn text_preview(kind: FileKind, path: &Path, source: &str) -> Result<Option<Preview>, Error> {
    Ok(Some(match kind {
        FileKind::Markdown => render_markdown(source),
        FileKind::Html => Preview::from_html(sanitize_html(source)),
        FileKind::Text => {
            let html = syntax::html_for_file(path, source).map_or_else(
                || format!("<pre class=\"plain\">{}</pre>", escape(source)),
                |code| format!("<pre class=\"plain\"><code>{code}</code></pre>"),
            );
            Preview::from_html(html)
        }
        FileKind::Mermaid => diagram("mermaid", source),
        FileKind::Vega => diagram("vega-lite", source),
        FileKind::Table => table(
            source,
            path.extension()
                .is_some_and(|ext| ext.eq_ignore_ascii_case("tsv")),
        )?,
        _ => return Ok(None),
    }))
}

#[derive(Debug, Serialize)]
pub struct Preview {
    pub html: String,
    pub headings: Vec<Heading>,
}

impl Preview {
    fn from_html(html: String) -> Self {
        Self {
            html,
            headings: Vec::new(),
        }
    }
}

#[derive(Debug, Serialize)]
pub struct Heading {
    pub id: String,
    pub title: String,
    pub level: u8,
}

pub(crate) fn decode_text(bytes: &[u8]) -> Result<(&str, bool), Error> {
    let stripped = bytes.strip_prefix(b"\xEF\xBB\xBF");
    let text = std::str::from_utf8(stripped.unwrap_or(bytes)).map_err(|_| Error::Encoding)?;
    if text.contains('\0') {
        return Err(Error::Encoding);
    }
    Ok((text, stripped.is_some()))
}

pub fn render_markdown(source: &str) -> Preview {
    let options = Options::ENABLE_TABLES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_FOOTNOTES
        | Options::ENABLE_GFM;
    let mut events = Vec::new();
    let mut headings = Vec::new();
    let mut current: Option<(usize, HeadingLevel, String)> = None;
    let mut used = HashSet::new();
    let mut code_block = None;
    let mut highlight_budget = syntax::MAX_HIGHLIGHT_BYTES;
    let mut line_budget = syntax::MAX_NUMBERED_LINES;
    for event in Parser::new_ext(source, options) {
        match &event {
            Event::Start(Tag::CodeBlock(kind)) => {
                let language = match kind {
                    CodeBlockKind::Fenced(info) => info.split_whitespace().next().unwrap_or(""),
                    CodeBlockKind::Indented => "",
                };
                if !matches!(language, "mermaid" | "vega-lite") {
                    let grammar = (highlight_budget > 0)
                        .then(|| syntax::for_token(language))
                        .flatten();
                    if line_budget > 0 || grammar.is_some() {
                        code_block = Some((events.len(), grammar));
                    }
                }
            }
            Event::End(TagEnd::CodeBlock) => {
                if let Some((start, grammar)) = code_block.take() {
                    let fragments = events[start + 1..].iter().filter_map(|event| match event {
                        Event::Text(text) => Some(text.as_ref()),
                        _ => None,
                    });
                    let source = fragments.collect::<String>();
                    let grammar = grammar.filter(|_| source.len() <= highlight_budget);
                    if grammar.is_some() {
                        highlight_budget -= source.len();
                    }
                    if let Some(code) = syntax::html(grammar, &source, &mut line_budget, false) {
                        events.truncate(start + 1);
                        events.push(Event::Html(code.into()));
                    }
                }
            }
            Event::Start(Tag::Heading { level, .. }) => {
                current = Some((events.len(), *level, String::new()));
            }
            Event::Text(text) | Event::Code(text) => {
                if let Some((_, _, title)) = current.as_mut() {
                    title.push_str(text);
                }
            }
            Event::SoftBreak | Event::HardBreak => {
                if let Some((_, _, title)) = current.as_mut() {
                    title.push(' ');
                }
            }
            Event::End(TagEnd::Heading(_)) => {
                if let Some((index, level, title)) = current.take() {
                    let id = heading_id(&title, &mut used);
                    events[index] = Event::Start(Tag::Heading {
                        level,
                        id: Some(id.clone().into()),
                        classes: Vec::new(),
                        attrs: Vec::new(),
                    });
                    headings.push(Heading {
                        id,
                        title,
                        level: level as u8,
                    });
                }
            }
            Event::Html(raw) | Event::InlineHtml(raw) => {
                // Treat inline author HTML as text here. Standalone HTML has a
                // dedicated sanitizer and does not gain Markdown-only controls.
                events.push(Event::Text(raw.clone()));
                continue;
            }
            _ => {}
        }
        events.push(event);
    }
    let mut body = String::new();
    html::push_html(&mut body, events.into_iter());
    Preview {
        html: sanitize_html(&body),
        headings,
    }
}

fn heading_id(title: &str, used: &mut HashSet<String>) -> String {
    let base = title
        .to_lowercase()
        .split_whitespace()
        .map(|word| {
            word.chars()
                .filter(|c| c.is_alphanumeric() || matches!(c, '_' | '-'))
                .collect::<String>()
        })
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>()
        .join("-");
    let base = if base.is_empty() { "section" } else { &base };
    let mut id = base.to_owned();
    let mut suffix = 1;
    while !used.insert(id.clone()) {
        id = format!("{base}-{suffix}");
        suffix += 1;
    }
    id
}

/// Produce an HTML fragment without executable markup. A host should also
/// restrict navigation, resource loads and scripting in its rendering surface.
pub fn sanitize_html(source: &str) -> String {
    ammonia::Builder::default()
        .add_generic_attributes(["id", "class", "title", "lang", "dir"])
        .add_tag_attributes("span", ["aria-hidden"])
        .add_tags(["input", "details", "summary"])
        .add_tag_attributes("input", ["type", "disabled", "checked"])
        .add_tag_attribute_values("input", "type", ["checkbox"])
        .set_tag_attribute_value("input", "disabled", "")
        .clean(source)
        .to_string()
}

fn diagram(language: &str, source: &str) -> Preview {
    Preview::from_html(format!(
        "<pre><code class=\"language-{language}\">{}</code></pre>",
        escape(source)
    ))
}

fn table(source: &str, is_tsv: bool) -> Result<Preview, Error> {
    const MAX_ROWS: usize = 500;
    const MAX_COLUMNS: usize = 80;
    let delimiter = if is_tsv { b'\t' } else { b',' };
    let mut reader = csv::ReaderBuilder::new()
        .delimiter(delimiter)
        .flexible(true)
        .from_reader(source.as_bytes());
    let mut html = String::from("<div class=\"table-scroll\"><table><thead><tr>");
    let headers = reader.headers()?;
    let mut truncated = headers.len() > MAX_COLUMNS;
    for field in headers.iter().take(MAX_COLUMNS) {
        html.push_str(&format!("<th scope=\"col\">{}</th>", escape(field)));
    }
    html.push_str("</tr></thead><tbody>");
    for (index, record) in reader.records().enumerate() {
        let record = record?;
        if index == MAX_ROWS {
            truncated = true;
            break;
        }
        truncated |= record.len() > MAX_COLUMNS;
        html.push_str("<tr>");
        for field in record.iter().take(MAX_COLUMNS) {
            html.push_str(&format!("<td>{}</td>", escape(field)));
        }
        html.push_str("</tr>");
    }
    html.push_str("</tbody></table></div>");
    if truncated {
        html.push_str("<p class=\"preview-note\">Showing up to 500 rows and 80 columns.</p>");
    }
    Ok(Preview::from_html(html))
}

pub(crate) fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

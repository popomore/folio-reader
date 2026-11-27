import type { ProductCopy } from '../site-kit/types';

export const messages = {
  copy: {
    "title": "Folio: view files from your agent",
    "description": "A macOS file viewer for documents, code, tables, diagrams, and media. Open local files in a quick preview or a workspace with tabs and split panes.",
    "eyebrow": "File viewer for macOS",
    "headline": [
      "View files",
      "from your agent"
    ],
    "intro": "Preview local documents, code, tables, diagrams, and media. Use the folio command to open a quick preview, then press Esc to close it.",
    "imageAlt": "Folio quick-preview window displaying Result.md as a Markdown document with a table.",
    "imageCaption": "Quick preview of Result.md.",
    "highlights": [
      {
        "title": "Local files",
        "description": "Open files and folders without importing them into a library."
      },
      {
        "title": "Tabs and split panes",
        "description": "Keep multiple files open and compare them side by side."
      },
      {
        "title": "Text editing",
        "description": "Edit supported UTF-8 files in source mode."
      }
    ],
    "story": {
      "label": "Workspace",
      "title": "Tabs and\nsplit panes",
      "paragraphs": [
        "Open two files side by side. Each pane has its own tabs and an adjustable width.",
        "Add folders to the sidebar, browse file paths, and navigate documents with the outline."
      ],
      "imageAlt": "Folio workspace showing Welcome.md and Reading List.md in left and right panes, with a file tree in the sidebar.",
      "imageCaption": "Two local files, two independent reading panes."
    },
    "featuresTitle": "Workspace features",
    "features": [
      {
        "title": "Markdown preview",
        "description": "View tables, task lists, code blocks, and a document outline. Adjust the font, text size, and reading width in Settings."
      },
      {
        "title": "Text editing",
        "description": "Switch supported UTF-8 files to source mode to edit and save them. Folio prompts you before closing a file with unsaved changes."
      },
      {
        "title": "Git changes and history",
        "description": "View workspace changes, file history, and diffs in a separate read-only Git view."
      }
    ],
    "detail": {
      "title": "Supported file formats",
      "description": "View documents, tables, diagrams, and media in the same application.",
      "items": [
        "Markdown & code",
        "PDF, HTML & RTF",
        "Images",
        "Audio & video",
        "CSV & TSV",
        "Mermaid & Vega-Lite"
      ],
      "note": "Image and media formats depend on macOS decoding. Editing is for supported UTF-8 text. DOCX, EPUB, and SVG can be opened with another application."
    },
    "stepsTitle": "Installation and setup",
    "steps": [
      {
        "title": "Install Folio",
        "description": "Download the macOS preview, open the disk image, and drag Folio to Applications."
      },
      {
        "title": "Open a file or folder",
        "description": "Use ⌘O to select a file or folder. Folders added to the sidebar remain available after relaunching Folio."
      },
      {
        "title": "Install the folio command",
        "description": "Follow the repository guide to install the bundled command. Use folio preview FILE to open a quick preview."
      }
    ],
    "faqTitle": "Questions",
    "faq": [
      {
        "question": "Do I have to import my files?",
        "answer": "No. Folio opens local files and folders directly. You can add multiple folders to the sidebar."
      },
      {
        "question": "Can Folio edit files?",
        "answer": "Supported UTF-8 Markdown, text, and code files can be edited in source mode. PDF, images, and other read-only formats can be previewed."
      },
      {
        "question": "Can Folio make Git commits?",
        "answer": "The Git view is read-only. It shows changes, file history, and diffs; it does not stage, commit, or push."
      },
      {
        "question": "Can I open files from Finder or the terminal?",
        "answer": "Yes. Folio includes a Markdown Quick Look extension for Finder and a bundled folio command. The repository guide explains how to enable the extension and install the command."
      }
    ],
    "downloadTitle": "Download Folio",
    "downloadDescription": "Download the macOS preview or build from source using the repository guide."
  } satisfies ProductCopy,
  page: {
    "contents": "On this page",
    "preview": "Quick preview",
    "formats": "Supported formats",
    "workspace": "Workspace",
    "get": "Download and source",
    "context": "View files from your agent",
    "flowTitle": "Open a preview from the terminal",
    "flow": [
      {
        "title": "Save a file",
        "body": "Have your agent save a document, table, or diagram as a local file."
      },
      {
        "title": "Open the preview",
        "body": "Run folio preview FILE to open a quick-preview window."
      },
      {
        "title": "Close or edit",
        "body": "Press Esc to close, or choose “Open in Folio” to use the workspace."
      }
    ],
    "command": "After installing the bundled folio command, an agent or script can open a file with:",
    "commandGuide": "Command setup and usage",
    "formatsTitle": "Supported file formats",
    "formatLabel": "Type",
    "formatExample": "Formats",
    "formatsList": [
      [
        "Documents & notes",
        "Markdown · PDF · RTF · HTML"
      ],
      [
        "Code & configuration",
        "UTF-8 text and source files"
      ],
      [
        "Tables",
        "CSV · TSV"
      ],
      [
        "Diagrams",
        "Mermaid · Vega-Lite"
      ],
      [
        "Media",
        "Images, audio, and video"
      ]
    ],
    "workspaceTitle": "Tabs, split panes, and text editing",
    "workspaceBody": "Choose “Open in Folio” from the preview window to use the workspace. Open multiple files, compare them side by side, and edit supported text files.",
    "workspaceNote": "The workspace includes folder navigation, tabs, and split panes.",
    "sourceTitle": "Download Folio",
    "sourceBody": "Download the macOS preview or build from source using the repository guide.",
    "questions": "Questions",
    "footer": "File viewer for macOS"
  },
  actions: {
    "get": "Download preview",
    "source": "View source",
    "releases": "All releases",
    "guide": "Getting started",
    "requirements": "macOS 14 or later · Apple Silicon",
    "image": "View full screenshot",
    "unavailable": "Source is available. A public download is not available yet.",
    "available": "A preview release, available from GitHub Releases.",
    "notes": "Release notes",
    "license": "MIT open source",
    "back": "Back to top"
  },
  accessibility: {
    "home": "home",
    "mainNavigation": "Main navigation",
    "footerLinks": "Footer links",
    "languageLabel": "用中文阅读此页",
    "languageName": "中文",
    "skipToContent": "Skip to content"
  },
  notFound: {
    "title": "Page not found",
    "description": "Page not found. Please return to the homepage.",
    "home": "English homepage"
  },
};

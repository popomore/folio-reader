import type { ProductCopy } from '../site-kit/types';

export const messages = {
  copy: {
    "title": "Folio：查看智能体生成的文件",
    "description": "macOS 文件查看器，支持文档、源码、表格、图表和媒体文件。可打开快速预览，也可使用带标签和分栏的工作区。",
    "eyebrow": "macOS 文件查看器",
    "headline": [
      "查看智能体",
      "生成的文件"
    ],
    "intro": "查看本地文档、源码、表格、图表和媒体文件。用 folio 命令打开快速预览，按 Esc 关闭。",
    "imageAlt": "Folio 快速预览窗口，显示 Result.md 的 Markdown 文档与表格。",
    "imageCaption": "Result.md 的快速预览。",
    "highlights": [
      {
        "title": "本地文件",
        "description": "直接打开文件和文件夹，无需导入资料库。"
      },
      {
        "title": "标签与分栏",
        "description": "同时打开多份文件，左右并排查看。"
      },
      {
        "title": "文本编辑",
        "description": "在源码模式中编辑支持的 UTF-8 文件。"
      }
    ],
    "story": {
      "label": "文件工作区",
      "title": "标签与\n左右分栏",
      "paragraphs": [
        "左右并排打开文件，每栏有独立的标签，宽度可以调整。",
        "在侧栏添加文件夹、浏览文件路径，用大纲跳转到文档标题。"
      ],
      "imageAlt": "Folio 工作区，左右分栏显示 Welcome.md 与 Reading List.md，侧栏为文件树。",
      "imageCaption": "两份本地文件，各自独立的阅读栏。"
    },
    "featuresTitle": "工作区功能",
    "features": [
      {
        "title": "Markdown 预览",
        "description": "支持表格、任务清单、代码块和文档大纲。可在设置中调整字体、字号与正文宽度。"
      },
      {
        "title": "文本编辑",
        "description": "支持的 UTF-8 文件可以切换到源码模式进行修改和保存。关闭未保存的文件前会提示确认。"
      },
      {
        "title": "Git 变更与历史",
        "description": "在独立的只读 Git 视图中查看工作区变更、文件历史和差异。"
      }
    ],
    "detail": {
      "title": "支持的文件格式",
      "description": "在同一应用中查看文档、表格、图表和媒体文件。",
      "items": [
        "Markdown 与源码",
        "PDF、HTML 与 RTF",
        "图片",
        "音频与视频",
        "CSV 与 TSV",
        "Mermaid 与 Vega-Lite"
      ],
      "note": "图片和媒体格式取决于 macOS 解码支持。编辑适用于支持的 UTF-8 文本；DOCX、EPUB 和 SVG 可交给其他应用打开。"
    },
    "stepsTitle": "安装与设置",
    "steps": [
      {
        "title": "安装 Folio",
        "description": "下载 macOS 预览版，打开磁盘映像，将 Folio 拖到「应用程序」。"
      },
      {
        "title": "打开文件或文件夹",
        "description": "用 ⌘O 选择文件或文件夹。添加到侧栏的文件夹会在重启后保留。"
      },
      {
        "title": "安装 folio 命令",
        "description": "按仓库指南安装应用附带的命令，使用 folio preview FILE 打开快速预览。"
      }
    ],
    "faqTitle": "常见问题",
    "faq": [
      {
        "question": "需要先导入文件吗？",
        "answer": "不需要。Folio 直接打开本地文件和文件夹，可以向侧栏添加多个文件夹。"
      },
      {
        "question": "Folio 能编辑文件吗？",
        "answer": "支持的 UTF-8 Markdown、文本和源码可以在源码模式中编辑；PDF、图片及其他只读格式可预览。"
      },
      {
        "question": "可以在 Folio 中提交 Git 吗？",
        "answer": "Git 视图只读，提供变更、文件历史和差异浏览，不进行暂存、提交或推送。"
      },
      {
        "question": "能从 Finder 或终端打开文件吗？",
        "answer": "可以。应用包含用于 Finder 的 Markdown 快速查看扩展和 folio 命令。启用扩展与安装命令的方法见仓库使用指南。"
      }
    ],
    "downloadTitle": "下载 Folio",
    "downloadDescription": "下载 macOS 预览版，或按仓库指南从源码构建。"
  } satisfies ProductCopy,
  page: {
    "contents": "本页内容",
    "preview": "快速预览",
    "formats": "支持的格式",
    "workspace": "文件工作区",
    "get": "下载与源码",
    "context": "查看智能体生成的文件",
    "flowTitle": "通过命令打开预览",
    "flow": [
      {
        "title": "保存文件",
        "body": "让智能体将文档、表格或图表保存为本地文件。"
      },
      {
        "title": "打开预览",
        "body": "运行 folio preview FILE，打开快速预览窗口。"
      },
      {
        "title": "关闭或编辑",
        "body": "按 Esc 关闭，或选择「Open in Folio」进入工作区。"
      }
    ],
    "command": "安装应用附带的 folio 命令后，智能体或脚本可用此命令打开文件：",
    "commandGuide": "查看命令安装与使用说明",
    "formatsTitle": "支持的文件格式",
    "formatLabel": "类型",
    "formatExample": "格式",
    "formatsList": [
      [
        "文档与笔记",
        "Markdown · PDF · RTF · HTML"
      ],
      [
        "源码与配置",
        "UTF-8 文本与常见源码文件"
      ],
      [
        "数据表格",
        "CSV · TSV"
      ],
      [
        "图表",
        "Mermaid · Vega-Lite"
      ],
      [
        "媒体",
        "图片、音频与视频"
      ]
    ],
    "workspaceTitle": "标签、分栏与文本编辑",
    "workspaceBody": "从预览窗口选择「Open in Folio」进入工作区。可以同时打开多个文件、左右对照，也可以编辑支持的文本文件。",
    "workspaceNote": "工作区支持文件夹导航、标签和左右分栏。",
    "sourceTitle": "下载 Folio",
    "sourceBody": "下载 macOS 预览版，或按仓库指南从源码构建。",
    "questions": "常见问题",
    "footer": "macOS 文件查看器"
  },
  actions: {
    "get": "下载预览版",
    "source": "查看源码",
    "releases": "所有版本",
    "guide": "使用指南",
    "requirements": "macOS 14 及以上 · Apple Silicon",
    "image": "查看完整截图",
    "unavailable": "当前提供源码，尚无公开安装包。",
    "available": "当前提供预览版。下载由 GitHub Releases 提供。",
    "notes": "此版本说明",
    "license": "MIT 开源",
    "back": "返回顶部"
  },
  accessibility: {
    "home": "首页",
    "mainNavigation": "主导航",
    "footerLinks": "页脚链接",
    "languageLabel": "Read this page in English",
    "languageName": "English",
    "skipToContent": "跳到正文"
  },
  notFound: {
    "title": "未找到页面",
    "description": "未找到页面，请返回首页。",
    "home": "中文首页 →"
  },
};

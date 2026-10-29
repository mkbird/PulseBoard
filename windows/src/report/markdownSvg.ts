const DEFAULT_WIDTH = 1_180;
const DEFAULT_MAX_HEIGHT = 30_000;
const OUTER_PADDING = 48;
const CONTENT_PADDING = 24;
const FONT_FAMILY = "Microsoft YaHei UI, Microsoft YaHei, Segoe UI, sans-serif";

type Alignment = "start" | "middle" | "end";

type MarkdownBlock =
  | { kind: "h1" | "h2" | "h3" | "paragraph"; text: string }
  | { kind: "quote"; lines: string[] }
  | { kind: "list"; ordered: boolean; items: string[] }
  | { kind: "table"; header: string[]; alignments: Alignment[]; rows: string[][] };

export interface MarkdownSVGOptions {
  width?: number;
  maxHeight?: number;
}

export interface MarkdownSVGResult {
  svg: string;
  width: number;
  height: number;
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.max(minimum, Math.min(maximum, value));
}

function escapeXML(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

function plainInline(value: string): string {
  return value
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/<br\s*\/?>/gi, " / ")
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/__([^_]+)__/g, "$1")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/\\([\\|*_`])/g, "$1")
    .trim();
}

function splitTableCells(row: string): string[] {
  let value = row.trim();
  if (value.startsWith("|")) value = value.slice(1);
  if (value.endsWith("|") && !value.endsWith("\\|")) value = value.slice(0, -1);

  const cells: string[] = [];
  let current = "";
  let escaped = false;
  for (const character of value) {
    if (escaped) {
      current += character === "|" ? "|" : `\\${character}`;
      escaped = false;
    } else if (character === "\\") {
      escaped = true;
    } else if (character === "|") {
      cells.push(plainInline(current));
      current = "";
    } else {
      current += character;
    }
  }
  if (escaped) current += "\\";
  cells.push(plainInline(current));
  return cells;
}

function isTableDivider(line: string): boolean {
  if (!line.trim().startsWith("|")) return false;
  const cells = splitTableCells(line);
  return cells.length > 0 && cells.every((cell) => /^:?-{3,}:?$/.test(cell.replaceAll(" ", "")));
}

function parseMarkdown(markdown: string): MarkdownBlock[] {
  const lines = markdown.replaceAll("\r\n", "\n").replaceAll("\r", "\n").split("\n");
  const blocks: MarkdownBlock[] = [];
  let index = 0;

  while (index < lines.length) {
    const line = lines[index] ?? "";
    const trimmed = line.trim();
    if (!trimmed) {
      index += 1;
      continue;
    }

    const heading = /^(#{1,3})\s+(.+)$/.exec(trimmed);
    if (heading) {
      const kind = heading[1]?.length === 1 ? "h1" : heading[1]?.length === 2 ? "h2" : "h3";
      blocks.push({ kind, text: plainInline(heading[2] ?? "") });
      index += 1;
      continue;
    }

    if (trimmed.startsWith(">")) {
      const quoteLines: string[] = [];
      while (index < lines.length && (lines[index] ?? "").trim().startsWith(">")) {
        const quote = (lines[index] ?? "").trim().slice(1).trim().replace(/^[-*]\s+/, "");
        if (quote) quoteLines.push(plainInline(quote));
        index += 1;
      }
      if (quoteLines.length) blocks.push({ kind: "quote", lines: quoteLines });
      continue;
    }

    if (trimmed.startsWith("|") && index + 1 < lines.length && isTableDivider(lines[index + 1] ?? "")) {
      const header = splitTableCells(trimmed);
      const alignments = splitTableCells(lines[index + 1] ?? "").map((cell): Alignment => {
        const compact = cell.replaceAll(" ", "");
        if (compact.startsWith(":") && compact.endsWith(":")) return "middle";
        if (compact.endsWith(":")) return "end";
        return "start";
      });
      index += 2;
      const rows: string[][] = [];
      while (index < lines.length && (lines[index] ?? "").trim().startsWith("|")) {
        const cells = splitTableCells(lines[index] ?? "");
        rows.push([...cells, ...Array(Math.max(0, header.length - cells.length)).fill("")].slice(0, header.length));
        index += 1;
      }
      blocks.push({ kind: "table", header, alignments, rows });
      continue;
    }

    const unordered = /^[-*]\s+(.+)$/.exec(trimmed);
    const ordered = /^\d+[.)]\s+(.+)$/.exec(trimmed);
    if (unordered || ordered) {
      const orderedList = ordered != null;
      const items: string[] = [];
      while (index < lines.length) {
        const candidate = (lines[index] ?? "").trim();
        const match = orderedList ? /^\d+[.)]\s+(.+)$/.exec(candidate) : /^[-*]\s+(.+)$/.exec(candidate);
        if (!match) break;
        items.push(plainInline(match[1] ?? ""));
        index += 1;
      }
      blocks.push({ kind: "list", ordered: orderedList, items });
      continue;
    }

    blocks.push({ kind: "paragraph", text: plainInline(trimmed) });
    index += 1;
  }

  return blocks;
}

function characterWidth(character: string, fontSize: number): number {
  if (/\s/u.test(character)) return fontSize * 0.34;
  if (/^[A-Z]$/u.test(character)) return fontSize * 0.66;
  if (/^[a-z0-9]$/u.test(character)) return fontSize * 0.56;
  if (/^[.,:;!?()[\]{}'"/\\+\-=]$/u.test(character)) return fontSize * 0.42;
  if (character.codePointAt(0)! > 0x2ff) return fontSize;
  return fontSize * 0.6;
}

function estimatedWidth(value: string, fontSize: number): number {
  return [...value].reduce((sum, character) => sum + characterWidth(character, fontSize), 0);
}

function wrapText(value: string, maximumWidth: number, fontSize: number, maximumLines = 20): string[] {
  const clean = value.trim();
  if (!clean) return [""];
  const lines: string[] = [];
  let current = "";
  let currentWidth = 0;
  let lastBreak = -1;

  const flush = (forceEllipsis = false): void => {
    let line = current.trimEnd();
    if (forceEllipsis && line && !line.endsWith("…")) line = `${line.replace(/[\s.,;:!?，。；：！？、]+$/u, "")}…`;
    lines.push(line || " ");
    current = "";
    currentWidth = 0;
    lastBreak = -1;
  };

  for (const character of clean) {
    const width = characterWidth(character, fontSize);
    if (current && currentWidth + width > maximumWidth) {
      if (lastBreak > 0) {
        const head = current.slice(0, lastBreak).trimEnd();
        const tail = current.slice(lastBreak).trimStart();
        lines.push(head || " ");
        current = tail;
        currentWidth = estimatedWidth(current, fontSize);
      } else {
        flush();
      }
      if (lines.length >= maximumLines) {
        const last = lines.length - 1;
        lines[last] = `${lines[last]?.replace(/[\s.,;:!?，。；：！？、]+$/u, "") ?? ""}…`;
        return lines;
      }
    }
    current += character;
    currentWidth += width;
    if (/\s|[-/，。；：！？、]/u.test(character)) lastBreak = current.length;
  }
  if (current || lines.length === 0) flush();
  return lines.slice(0, maximumLines);
}

function numeric(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(2).replace(/0+$/u, "").replace(/\.$/u, "");
}

function rect(x: number, y: number, width: number, height: number, fill: string, stroke = "none", radius = 0): string {
  return `<rect x="${numeric(x)}" y="${numeric(y)}" width="${numeric(width)}" height="${numeric(height)}" rx="${numeric(radius)}" fill="${fill}" stroke="${stroke}"/>`;
}

function textElement(
  lines: string[],
  x: number,
  baselineY: number,
  lineHeight: number,
  fontSize: number,
  fill: string,
  weight = 400,
  anchor: Alignment = "start",
): string {
  const spans = lines.map((line, index) => (
    `<tspan x="${numeric(x)}" y="${numeric(baselineY + index * lineHeight)}">${escapeXML(line)}</tspan>`
  )).join("");
  return `<text font-family="${FONT_FAMILY}" font-size="${numeric(fontSize)}" font-weight="${weight}" fill="${fill}" text-anchor="${anchor}" xml:space="preserve">${spans}</text>`;
}

/**
 * Turns the fixed CliptoPulse morning-report Markdown subset into a standalone SVG.
 * The SVG intentionally contains only vector primitives and system-font text, so a
 * browser can rasterize it to PNG without foreignObject, network access or native modules.
 */
export function renderMarkdownReportSVG(
  markdown: string,
  options: MarkdownSVGOptions = {},
): MarkdownSVGResult {
  const width = Math.round(clamp(options.width ?? DEFAULT_WIDTH, 720, 2_000));
  const maxHeight = Math.round(clamp(options.maxHeight ?? DEFAULT_MAX_HEIGHT, 600, 32_000));
  const contentWidth = width - OUTER_PADDING * 2;
  const blocks = parseMarkdown(markdown);
  const elements: string[] = [];
  let y = 0;
  let truncated = false;

  const hasRoom = (height: number): boolean => {
    if (y + height + OUTER_PADDING <= maxHeight) return true;
    truncated = true;
    return false;
  };

  const renderHeading = (kind: "h1" | "h2" | "h3", value: string): void => {
    if (kind === "h1") {
      const fontSize = 36;
      const lineHeight = 48;
      const lines = wrapText(value || "Clipto 离线分析性能晨报", contentWidth, fontSize, 4);
      const height = 142 + (lines.length - 1) * lineHeight;
      if (!hasRoom(height)) return;
      elements.push(rect(0, 0, width, height, "url(#header-gradient)"));
      elements.push(rect(OUTER_PADDING, 28, 154, 28, "rgba(255,255,255,0.14)", "rgba(255,255,255,0.3)", 14));
      elements.push(textElement(["CliptoPulse 晨报"], OUTER_PADDING + 77, 47, 18, 12, "#ffffff", 700, "middle"));
      elements.push(textElement(lines, OUTER_PADDING, 96, lineHeight, fontSize, "#ffffff", 800));
      y = height + 28;
      return;
    }

    const fontSize = kind === "h2" ? 24 : 18;
    const lineHeight = kind === "h2" ? 32 : 26;
    const lines = wrapText(value, contentWidth - 32, fontSize, 5);
    const height = lines.length * lineHeight + (kind === "h2" ? 34 : 20);
    if (!hasRoom(height)) return;
    if (kind === "h2") {
      elements.push(rect(OUTER_PADDING, y, contentWidth, height, "#ffffff", "#e2e8f0", 14));
      elements.push(rect(OUTER_PADDING, y, 7, height, "#4f46e5", "none", 4));
      elements.push(textElement(lines, OUTER_PADDING + 26, y + 31, lineHeight, fontSize, "#172554", 750));
    } else {
      elements.push(textElement(lines, OUTER_PADDING + 8, y + 22, lineHeight, fontSize, "#3730a3", 700));
    }
    y += height + 14;
  };

  if (blocks[0]?.kind !== "h1") {
    const titleHeight = 118;
    elements.push(rect(0, 0, width, titleHeight, "url(#header-gradient)"));
    elements.push(textElement(["CliptoPulse 离线分析性能晨报"], OUTER_PADDING, 72, 42, 34, "#ffffff", 800));
    y = titleHeight + 28;
  }

  for (const block of blocks) {
    if (truncated) break;
    if (block.kind === "h1" || block.kind === "h2" || block.kind === "h3") {
      renderHeading(block.kind, block.text);
      continue;
    }

    if (block.kind === "paragraph") {
      const lines = wrapText(block.text, contentWidth - CONTENT_PADDING * 2, 15, 30);
      const lineHeight = 24;
      const height = lines.length * lineHeight + CONTENT_PADDING * 2;
      if (!hasRoom(height)) break;
      elements.push(rect(OUTER_PADDING, y, contentWidth, height, "#ffffff", "#e2e8f0", 12));
      elements.push(textElement(lines, OUTER_PADDING + CONTENT_PADDING, y + CONTENT_PADDING + 15, lineHeight, 15, "#334155", 400));
      y += height + 12;
      continue;
    }

    if (block.kind === "quote") {
      const lineHeight = 23;
      const wrapped = block.lines.flatMap((line) => wrapText(line, contentWidth - 62, 14, 12));
      const height = wrapped.length * lineHeight + 34;
      if (!hasRoom(height)) break;
      elements.push(rect(OUTER_PADDING, y, contentWidth, height, "#eef2ff", "#c7d2fe", 12));
      elements.push(rect(OUTER_PADDING, y, 6, height, "#6366f1", "none", 3));
      elements.push(textElement(wrapped, OUTER_PADDING + 26, y + 27, lineHeight, 14, "#3730a3", 500));
      y += height + 14;
      continue;
    }

    if (block.kind === "list") {
      const lineHeight = 23;
      const rows = block.items.map((item, itemIndex) => ({
        marker: block.ordered ? `${itemIndex + 1}.` : "•",
        lines: wrapText(item, contentWidth - 80, 14, 16),
      }));
      const height = rows.reduce((sum, row) => sum + row.lines.length * lineHeight + 6, 28);
      if (!hasRoom(height)) break;
      elements.push(rect(OUTER_PADDING, y, contentWidth, height, "#ffffff", "#e2e8f0", 12));
      let rowY = y + 26;
      for (const row of rows) {
        elements.push(textElement([row.marker], OUTER_PADDING + 22, rowY, lineHeight, 14, "#4f46e5", 700));
        elements.push(textElement(row.lines, OUTER_PADDING + 50, rowY, lineHeight, 14, "#334155", 400));
        rowY += row.lines.length * lineHeight + 6;
      }
      y += height + 14;
      continue;
    }

    if (block.kind !== "table") continue;
    const columnCount = Math.max(1, block.header.length);
    const columnWidth = contentWidth / columnCount;
    const tableRows = [block.header, ...block.rows];
    const fontSize = columnCount >= 6 ? 12 : 13;
    const lineHeight = fontSize + 6;
    const wrappedRows = tableRows.map((row) => row.map((cell) => wrapText(cell, columnWidth - 20, fontSize, 10)));
    const rowHeights = wrappedRows.map((row) => Math.max(40, ...row.map((lines) => lines.length * lineHeight + 18)));
    const totalHeight = rowHeights.reduce((sum, rowHeight) => sum + rowHeight, 0);
    if (!hasRoom(totalHeight + 2)) break;

    let tableY = y;
    for (let rowIndex = 0; rowIndex < wrappedRows.length; rowIndex += 1) {
      const rowHeight = rowHeights[rowIndex] ?? 40;
      const fill = rowIndex === 0 ? "#e0e7ff" : (rowIndex % 2 === 0 ? "#f8fafc" : "#ffffff");
      for (let columnIndex = 0; columnIndex < columnCount; columnIndex += 1) {
        const cellX = OUTER_PADDING + columnIndex * columnWidth;
        elements.push(rect(cellX, tableY, columnWidth, rowHeight, fill, "#cbd5e1"));
        const alignment = block.alignments[columnIndex] ?? "start";
        const anchorX = alignment === "middle"
          ? cellX + columnWidth / 2
          : alignment === "end" ? cellX + columnWidth - 10 : cellX + 10;
        elements.push(textElement(
          wrappedRows[rowIndex]?.[columnIndex] ?? [""],
          anchorX,
          tableY + 17,
          lineHeight,
          fontSize,
          rowIndex === 0 ? "#312e81" : "#334155",
          rowIndex === 0 ? 700 : 400,
          alignment,
        ));
      }
      tableY += rowHeight;
    }
    y = tableY + 16;
  }

  if (truncated) {
    const noticeHeight = 52;
    const noticeY = Math.min(y, maxHeight - OUTER_PADDING - noticeHeight);
    elements.push(rect(OUTER_PADDING, noticeY, contentWidth, noticeHeight, "#fff7ed", "#fdba74", 10));
    elements.push(textElement(["报告内容过长，图片已在安全高度处截断。"], OUTER_PADDING + 20, noticeY + 32, 20, 14, "#9a3412", 600));
    y = noticeY + noticeHeight + 18;
  }

  const footerY = Math.min(y + 8, maxHeight - 34);
  elements.push(textElement(["Generated by CliptoPulse"], width - OUTER_PADDING, footerY + 16, 18, 12, "#94a3b8", 500, "end"));
  const height = Math.max(220, Math.min(maxHeight, Math.ceil(footerY + 38)));
  const definitions = `<defs><linearGradient id="header-gradient" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#111827"/><stop offset="0.55" stop-color="#312e81"/><stop offset="1" stop-color="#1d4ed8"/></linearGradient></defs>`;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">${definitions}${rect(0, 0, width, height, "#f1f5f9")}${elements.join("")}</svg>`;
  return { svg, width, height };
}

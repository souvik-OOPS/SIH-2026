/**
 * Render a Markdown file to PDF through headless Chrome.
 *
 * Print-specific choices: light palette regardless of OS theme (this gets
 * printed on white paper), A4 with real margins, 11pt body so code and tables
 * stay readable, and page-break rules so a heading never lands alone at the
 * bottom of a page.
 *
 * Usage: node md2pdf.mjs <input.md> <output.pdf> ["Document title"]
 */
import { readFileSync, writeFileSync, unlinkSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { marked } from 'marked'
import { chromium } from 'playwright-core'

const [, , inPath, outPath, titleArg] = process.argv
if (!inPath || !outPath) {
  console.error('usage: node md2pdf.mjs <input.md> <output.pdf> ["title"]')
  process.exit(1)
}

const md = readFileSync(inPath, 'utf8')
marked.setOptions({ gfm: true, breaks: false })
const body = marked.parse(md)

const title = titleArg || 'Document'

const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>${title}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans+Condensed:wght@600;700&family=IBM+Plex+Sans:wght@400;500;600&display=swap">
<style>
  :root {
    --ink: #14181d;
    --ink-mid: #444e5a;
    --ink-dim: #6a7683;
    --rule: #d8dee6;
    --rule-soft: #e8edf2;
    --surface: #f5f8fa;
    --accent: #1a6ea8;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; background: #fff; }
  body {
    font-family: 'IBM Plex Sans', system-ui, sans-serif;
    font-size: 10.5pt;
    line-height: 1.55;
    color: var(--ink);
    -webkit-print-color-adjust: exact;
    print-color-adjust: exact;
  }

  h1, h2, h3, h4 {
    font-family: 'IBM Plex Sans Condensed', 'IBM Plex Sans', sans-serif;
    line-height: 1.15;
    margin: 1.4em 0 .45em;
    break-after: avoid;
    page-break-after: avoid;
  }
  h1 {
    font-size: 25pt; font-weight: 700; letter-spacing: -.01em;
    margin: 0 0 .3em; padding-bottom: .28em;
    border-bottom: 2px solid var(--ink);
  }
  h2 {
    font-size: 15pt; font-weight: 700; margin-top: 1.7em;
    padding-bottom: .2em; border-bottom: 1px solid var(--rule);
  }
  h3 { font-size: 12pt; font-weight: 600; color: var(--ink-mid); }

  p, ul, ol { margin: 0 0 .75em; }
  li { margin-bottom: .25em; }
  li::marker { color: var(--ink-dim); }
  strong { font-weight: 600; }

  a { color: var(--accent); text-decoration: none; }

  code {
    font-family: 'IBM Plex Mono', monospace;
    font-size: .86em;
    background: var(--surface);
    border: 1px solid var(--rule-soft);
    border-radius: 3px;
    padding: .5pt 3pt;
  }

  pre {
    background: var(--surface);
    border: 1px solid var(--rule-soft);
    border-left: 3px solid var(--rule);
    border-radius: 4px;
    padding: 9pt 11pt;
    overflow-x: auto;
    break-inside: avoid;
    page-break-inside: avoid;
    margin: 0 0 1em;
  }
  pre code {
    background: none; border: 0; padding: 0;
    font-size: 8.4pt; line-height: 1.45; white-space: pre;
  }

  table {
    width: 100%;
    border-collapse: collapse;
    margin: 0 0 1.1em;
    font-size: 9.3pt;
    break-inside: avoid;
    page-break-inside: avoid;
  }
  th {
    text-align: left;
    font-family: 'IBM Plex Mono', monospace;
    font-size: 7.8pt;
    font-weight: 500;
    letter-spacing: .07em;
    text-transform: uppercase;
    color: var(--ink-dim);
    border-bottom: 1.5px solid var(--rule);
    padding: 0 8pt 4pt 0;
  }
  td {
    padding: 4.5pt 8pt 4.5pt 0;
    border-bottom: 1px solid var(--rule-soft);
    vertical-align: top;
  }
  td:first-child { white-space: nowrap; }

  blockquote {
    margin: 0 0 1em;
    padding: 2pt 0 2pt 12pt;
    border-left: 3px solid var(--rule);
    color: var(--ink-mid);
  }
  blockquote p:last-child { margin-bottom: 0; }

  hr { border: 0; border-top: 1px solid var(--rule); margin: 1.6em 0; }

  /* Keep a heading with the block that follows it. */
  h2 + p, h2 + ul, h2 + table, h3 + p, h3 + ul, h3 + table { break-before: avoid; }
</style></head><body>
${body}
</body></html>`

const tmpHtml = outPath.replace(/\.pdf$/i, '.tmp.html')
writeFileSync(tmpHtml, html, 'utf8')

const browser = await chromium.launch({ channel: 'chrome', args: ['--no-sandbox'] })
const page = await browser.newPage()

await page.goto(pathToFileURL(tmpHtml).href, { waitUntil: 'networkidle' })
// Webfonts load over the network; without this the PDF can bake the fallback face.
await page.evaluate(() => document.fonts.ready)

await page.pdf({
  path: outPath,
  format: 'A4',
  printBackground: true,
  margin: { top: '18mm', bottom: '18mm', left: '16mm', right: '16mm' },
  displayHeaderFooter: true,
  headerTemplate: '<div></div>',
  footerTemplate:
    `<div style="width:100%;font-family:'IBM Plex Mono',monospace;font-size:7pt;color:#8a94a0;padding:0 16mm;display:flex;justify-content:space-between;">
       <span>${title}</span><span class="pageNumber"></span>
     </div>`,
})

await browser.close()
unlinkSync(tmpHtml)

const { size } = await import('node:fs').then((fs) => fs.statSync(outPath))
console.log(`  ${outPath}  (${(size / 1024).toFixed(0)} KB)`)

// Rasterize exported UI trees for offline visual review. Flex/text layout is
// approximated by Chromium; these images do not claim native Roblox rendering.
// PLAYWRIGHT_MODULE may point to an external Playwright installation.
// node test/render_mobile.js <snapshot directory> [baseline directory]
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { pathToFileURL } = require('node:url');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const directory = path.resolve(process.argv[2] || 'refer/mobile-20260921/current');
const baseline = process.argv[3] && path.resolve(process.argv[3]);
const escape = text => String(text ?? '').replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch]);
const dimension = (scale = 0, offset = 0) => scale ? `calc(${scale * 100}% + ${offset}px)` : `${offset}px`;
const color = (rgb = [1, 1, 1], transparency = 0) => `rgba(${rgb.map(v => Math.round(v * 255)).join(',')},${1 - transparency})`;
const component = (node, kind) => (node.children || []).find(child => child.class === kind)?.props;
const auto = (props, axis) => props.AutomaticSize === axis || props.AutomaticSize === 'XY';
const alignment = name => ({ Left: 'flex-start', Right: 'flex-end', Top: 'flex-start', Bottom: 'flex-end', Center: 'center' })[name] || 'flex-start';
const interpolate = (sequence, position, fallback) => {
  const points = sequence?.keypoints;
  if (!points?.length) return fallback;
  let right = points.findIndex(point => point.time >= position);
  if (right <= 0) return points[right === -1 ? points.length - 1 : 0].value;
  const a = points[right - 1], b = points[right], weight = (position - a.time) / Math.max(1e-9, b.time - a.time);
  return Array.isArray(a.value) ? a.value.map((value, index) => value + (b.value[index] - value) * weight) : a.value + (b.value - a.value) * weight;
};

function render(node, parentLayout = null, parentProps = {}) {
  const p = node.props, list = component(node, 'UIListLayout');
  const isRoot = node.class === 'ScreenGui';
  const size = p.Size || [0, 0, 0, 0], pos = p.Position || [0, 0, 0, 0], anchor = p.AnchorPoint || [0, 0];
  const flex = component(node, 'UIFlexItem');
  const style = { position: parentLayout ? 'relative' : 'absolute', boxSizing: 'border-box', flexShrink: '0',
    width: isRoot ? '100%' : dimension(size[0], size[1]), height: isRoot ? '100%' : dimension(size[2], size[3]),
    minWidth: '0', minHeight: '0', zIndex: p.ZIndex || 1 };
  if (!parentLayout) {
    style.left = dimension(pos[0], pos[1]); style.top = dimension(pos[2], pos[3]);
    style.transform = `translate(${-anchor[0] * 100}%,${-anchor[1] * 100}%) rotate(${p.Rotation || 0}deg)`;
  }
  if (auto(p, 'X') && !size[0]) { style.width = 'max-content'; style.minWidth = `${size[1]}px`; }
  if (auto(p, 'Y') && !size[2]) { style.height = 'max-content'; style.minHeight = `${size[3]}px`; }
  // Roblox AutomaticSize measures offset-sized descendants even when their
  // position is absolute. Let these intrinsic content wrappers contribute size.
  if (!parentLayout && auto(parentProps, 'X') && !size[0] && !pos.some(Boolean) && !anchor.some(Boolean)) {
    style.position = 'relative';
  }
  if (parentLayout && auto(parentProps, 'Y') && size[2] === 1 && size[3] === 0) style.height = 'auto';
  if (parentLayout && flex && ['Fill', 'Grow', 'Shrink'].includes(flex.FlexMode)) {
    style.flex = flex.FlexMode === 'Shrink' ? '0 1 auto' : '1 1 0px';
    if (flex.FlexMode !== 'Shrink') {
      if (parentLayout.FillDirection === 'Horizontal') style.width = '0'; else style.height = '0';
    }
  }
  const constraint = component(node, 'UISizeConstraint');
  if (constraint) {
    if (constraint.MinSize) [style.minWidth, style.minHeight] = constraint.MinSize.map(n => `${n}px`);
    if (constraint.MaxSize) [style.maxWidth, style.maxHeight] = constraint.MaxSize.map(n => `${n}px`);
  }
  const padding = component(node, 'UIPadding');
  if (padding) for (const side of ['Left', 'Right', 'Top', 'Bottom']) {
    style[`padding${side}`] = dimension(...(padding[`Padding${side}`] || [0, 0]));
  }
  const corner = component(node, 'UICorner')?.CornerRadius;
  if (corner) style.borderRadius = corner[0] ? '50%' : `${corner[1]}px`;
  if ((p.BackgroundTransparency ?? 0) < 1 && !isRoot) style.background = color(p.BackgroundColor3, p.BackgroundTransparency || 0);
  const gradient = component(node, 'UIGradient');
  if (gradient && (gradient.Color?.keypoints || gradient.Transparency?.keypoints)) {
    const positions = [...new Set([0, 1, ...(gradient.Color?.keypoints || []).map(point => point.time),
      ...(gradient.Transparency?.keypoints || []).map(point => point.time)])].sort((a, b) => a - b);
    const base = p.BackgroundColor3 || [1, 1, 1];
    const stops = positions.map(position => {
      const rgb = interpolate(gradient.Color, position, [1, 1, 1]).map((value, index) => value * base[index]);
      const opacity = (1 - (p.BackgroundTransparency || 0)) * (1 - interpolate(gradient.Transparency, position, 0));
      return color(rgb, 1 - opacity) + ' ' + position * 100 + '%';
    });
    style.background = 'linear-gradient(' + (90 + (gradient.Rotation || 0)) + 'deg,' + stops.join(',') + ')';
  }
  const stroke = component(node, 'UIStroke');
  if (stroke && (stroke.Transparency ?? 0) < 1) style.boxShadow = `inset 0 0 0 ${stroke.Thickness || 1}px ${color(stroke.Color, stroke.Transparency || 0)}`;
  if (p.ClipsDescendants) style.overflow = 'hidden';
  if (list) {
    style.display = 'flex'; style.flexDirection = list.FillDirection === 'Horizontal' ? 'row' : 'column';
    style.gap = dimension(...(list.Padding || [0, 0]));
    style.justifyContent = alignment(list.FillDirection === 'Horizontal' ? list.HorizontalAlignment : list.VerticalAlignment);
    style.alignItems = alignment(list.FillDirection === 'Horizontal' ? list.VerticalAlignment : list.HorizontalAlignment);
    if (list.Wraps) style.flexWrap = 'wrap';
  }
  if (node.class === 'ScrollingFrame') {
    style.overflow = 'hidden';
    if (p.ScrollingEnabled !== false) {
      style.overflowX = p.ScrollingDirection === 'X' || p.ScrollingDirection === 'XY' ? 'auto' : 'hidden';
      style.overflowY = p.ScrollingDirection === 'Y' || p.ScrollingDirection === 'XY' ? 'auto' : 'hidden';
    }
    style['--scrollbar'] = `${p.ScrollBarThickness || 0}px`;
  }
  let contents = '';
  if (p.Text !== undefined && p.Text !== '') {
    const text = p.RichText ? String(p.Text).replace(/<[^>]+>/g, '') : p.Text;
    style.color = color(p.TextColor3, p.TextTransparency || 0);
    style.fontFamily = /Code|Mono|UbuntuMono/.test(p.Font || '') ? 'Consolas, monospace' : 'Arial, sans-serif';
    style.fontWeight = /Bold|Semibold|Medium/.test(p.Font || '') ? '600' : '400';
    style.fontSize = `${p.TextSize || 14}px`; style.lineHeight = p.LineHeight || 1;
    style.textAlign = (p.TextXAlignment || 'Center').toLowerCase();
    style.display = 'flex'; style.flexDirection = 'column';
    style.justifyContent = alignment(p.TextYAlignment || 'Center');
    contents = `<span style="display:block;width:100%;flex-shrink:0;white-space:${p.TextWrapped ? 'pre-wrap' : 'pre'};overflow:hidden;overflow-wrap:anywhere;text-overflow:${p.TextTruncate === 'AtEnd' ? 'ellipsis' : 'clip'}">${escape(text)}</span>`;
  } else if (node.class === 'TextBox' && p.PlaceholderText) {
    style.fontFamily = 'Arial, sans-serif'; style.fontSize = `${p.TextSize || 14}px`;
    style.color = color(p.PlaceholderColor3); style.display = 'flex'; style.alignItems = 'center';
    contents = `<span style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${escape(p.PlaceholderText)}</span>`;
  }
  if (p.Image) {
    const asset = path.join(__dirname, '..', 'assets', 'icons', path.basename(p.Image));
    if (fs.existsSync(asset)) {
      const data = fs.readFileSync(asset).toString('base64');
      contents += `<div style="position:absolute;inset:0;background:${color(p.ImageColor3, p.ImageTransparency || 0)};mask:url(data:image/png;base64,${data}) center / contain no-repeat"></div>`;
    }
  }
  const children = (node.children || []).filter(child => !child.class.startsWith('UI'));
  if (list) children.sort((a, b) => (a.props.LayoutOrder || 0) - (b.props.LayoutOrder || 0));
  contents += children.map(child => render(child, list, p)).join('');
  if (p.Visible === false) style.display = 'none';
  const css = Object.entries(style).map(([key, value]) => `${key.replace(/[A-Z]/g, m => '-' + m.toLowerCase())}:${value}`).join(';');
  return `<div data-name="${escape(node.name)}" data-class="${node.class}" data-scroll="${escape(JSON.stringify(p.CanvasPosition || [0, 0]))}" style="${css}">${contents}</div>`;
}

(async () => {
  const filter = process.env.UAI_SCENE_FILTER && new RegExp(process.env.UAI_SCENE_FILTER);
  const files = fs.readdirSync(directory).filter(file => file.endsWith('.json') && (!filter || filter.test(file))).sort();
  const browser = await chromium.launch({ headless: true });
  let compared = 0;
  try {
    for (const file of files) {
      const snapshot = JSON.parse(fs.readFileSync(path.join(directory, file), 'utf8'));
      if (baseline && file.startsWith('desktop-')) {
        const before = JSON.parse(fs.readFileSync(path.join(baseline, file), 'utf8'));
        assert.deepEqual(snapshot.root, before.root, `Desktop UI changed: ${file}`);
        compared++;
      }
      const html = `<!doctype html><meta charset="utf-8"><style>body{margin:0;background:#182028}::-webkit-scrollbar{width:var(--scrollbar,3px);height:var(--scrollbar,3px)}::-webkit-scrollbar-thumb{background:#5b5652;border-radius:4px}</style>
        <main style="position:relative;width:${snapshot.width}px;height:${snapshot.height}px">${render(snapshot.root)}
        ${snapshot.keyboard ? `<div style="position:absolute;left:0;right:0;bottom:0;height:${snapshot.keyboard}px;background:#30343b;border-top:1px solid #68707a;color:#b3bac4;display:grid;place-items:center;font:14px Arial;z-index:100000">On-screen keyboard (${snapshot.keyboard}px)</div>` : ''}</main>
        <footer style="height:26px;background:#0e141b;color:#aeb9c5;font:12px/26px Arial;padding-left:12px">${escape(snapshot.engine || 'Lune')} layout preview · approximate text rendering · ${escape(snapshot.name)}</footer>`;
      const output = path.join(directory, file.replace(/\.json$/, '.html'));
      fs.writeFileSync(output, html);
      const page = await browser.newPage({ viewport: { width: snapshot.width, height: snapshot.height + 26 }, deviceScaleFactor: 1 });
      await page.goto(pathToFileURL(output).href);
      await page.evaluate(() => {
        for (const node of document.querySelectorAll('[data-scroll]')) {
          const [x, y] = JSON.parse(node.dataset.scroll); node.scrollLeft = x; node.scrollTop = y;
        }
      });
      await page.screenshot({ path: output.replace(/\.html$/, '.png'), animations: 'disabled' });
      await page.close();
    }
  } finally { await browser.close(); }
  console.log(`Rendered ${files.length} approximate UI layout images.`);
  if (baseline) console.log(`${compared} desktop trees match the release exactly.`);
})().catch(error => { console.error(error); process.exitCode = 1; });

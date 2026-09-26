/* Safe Markdown shared by transcript, thinking, and tool previews. */
(function(root) {
  const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  function inline(text) {
    const slots = []; let sentinel = '\u0001';
    while (text.includes(sentinel)) sentinel += '\u0001';
    text = text.replace(/(`+)([\s\S]*?)\1|\\([\\`*_|<>])/g, (_, ticks, code, literal) => {
      slots.push(literal ? escape(literal) : `<code>${escape(code)}</code>`); return sentinel + (slots.length - 1) + sentinel;
    });
    text = escape(text).replace(/\*\*(.+?)\*\*/g,'<strong>$1</strong>').replace(/\*([^*]+)\*/g,'<em>$1</em>');
    return text.replace(new RegExp(sentinel + '(\\d+)' + sentinel, 'g'), (_, id) => slots[Number(id)]);
  }
  function cells(line) {
    const parts = []; let part = '', code = 0;
    for (let i=0;i<line.length;i++) {
      if (line[i] === '\\' && line[i+1] === '|') { part += '|'; i++; continue; }
      if (line[i] === '`') { let n=1; while(line[i+n] === '`') n++; code = code === n ? 0 : (code || n); part += '`'.repeat(n); i+=n-1; }
      else if (line[i] === '|' && !code) { parts.push(part.trim()); part=''; }
      else part += line[i];
    }
    parts.push(part.trim()); if(parts[0] === '') parts.shift(); if(parts.at(-1) === '') parts.pop(); return parts;
  }
  function render(value) {
    const lines = String(value || '').replace(/\r\n/g,'\n').split('\n'), out=[];
    for(let i=0;i<lines.length;i++) {
      const line=lines[i], fence=line.match(/^\s*(`{3,}|~{3,})(\S*)/);
      if(fence) {
        const code=[]; while(++i<lines.length && !new RegExp('^\\s*'+fence[1][0]+'{'+fence[1].length+',}\\s*$').test(lines[i])) code.push(lines[i]);
        out.push(`<div class="code-block"><div class="code-head"><span>${escape(fence[2] || 'code')}</span><button type="button" class="copy-code" aria-label="Copy code">Copy</button></div><pre tabindex="0" aria-label="Code block"><code>${escape(code.join('\n'))}</code></pre></div>`); continue;
      }
      const delimiter=i+1<lines.length ? cells(lines[i+1]) : [];
      if(line.includes('|') && delimiter.length && delimiter.every(s=>/^:?-+:?$/.test(s)) && delimiter.length===cells(line).length) {
        const head=cells(line), rows=[]; i++;
        while(i+1<lines.length && lines[i+1].trim() && lines[i+1].includes('|')) rows.push(cells(lines[++i]));
        const align=c=>delimiter[c]?.endsWith(':')?(delimiter[c].startsWith(':')?'center':'right'):'left';
        const row=(values, tag)=>'<tr>'+values.map((v,c)=>`<${tag} class="md-${align(c)}">${inline(v)}</${tag}>`).join('')+'</tr>';
        out.push('<div class="table-scroll" tabindex="0" role="region" aria-label="Scrollable table"><table><thead>'+row(head,'th')+'</thead><tbody>'+rows.map(r=>row(r,'td')).join('')+'</tbody></table></div>'); continue;
      }
      if(!line.trim()) continue;
      const heading=line.match(/^(#{1,6})\s+(.+)/); if(heading) {out.push(`<h${heading[1].length}>${inline(heading[2])}</h${heading[1].length}>`);continue;}
      if(/^>\s?/.test(line)){out.push('<blockquote>'+inline(line.replace(/^>\s?/,''))+'</blockquote>');continue;}
      if(/^\s*([-*+] |\d+[.)] )/.test(line)){const ordered=/^\s*\d/.test(line), items=[];do{items.push('<li>'+inline(lines[i].replace(/^\s*(?:[-*+]|\d+[.)])\s+/,''))+'</li>');i++;}while(i<lines.length&&/^\s*([-*+] |\d+[.)] )/.test(lines[i]));i--;const tag=ordered?'ol':'ul';out.push(`<${tag}>${items.join('')}</${tag}>`);continue;}
      out.push('<p>'+inline(line)+'</p>');
    }
    return out.join('');
  }
  root.UAIMarkdown={render,escape,inline};
  if(typeof module!=='undefined') module.exports=root.UAIMarkdown;
})(typeof window!=='undefined'?window:globalThis);

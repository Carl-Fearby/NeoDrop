import Foundation

/// The deleted-files page, served whole from `WebUIServer`.
///
/// One self-contained document: no external stylesheet, font, image or script, because the page
/// is loaded by a web view that has no business reaching the network. It talks to the same origin
/// through two relative endpoints, so the URL token never appears in the markup and the page keeps
/// working when the port changes next launch.
enum WebUIPage {
    static func html(retentionDays: Int) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Deleted Files — NeoDrop</title>
        <style>
        :root {
          color-scheme: light dark;
          --bg: #f5f5f7;
          --panel: #ffffff;
          --text: #1d1d1f;
          --muted: #6e6e73;
          --line: rgba(0,0,0,0.08);
          --accent: #0071e3;
          --accent-text: #ffffff;
          --warn: #fff3cd;
          --warn-text: #664d03;
          --good: #e3f6e6;
          --good-text: #14602a;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #1c1c1e;
            --panel: #2c2c2e;
            --text: #f5f5f7;
            --muted: #98989d;
            --line: rgba(255,255,255,0.10);
            --accent: #0a84ff;
            --warn: #3a2f0b;
            --warn-text: #ffe08a;
            --good: #12331c;
            --good-text: #8ce6a5;
          }
        }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          padding: 24px 22px 40px;
          background: var(--bg);
          color: var(--text);
          font: 13px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
        }
        header { max-width: 720px; margin: 0 auto 16px; display: flex; align-items: flex-start; gap: 12px; }
        h1 { font-size: 22px; line-height: 1.2; margin: 0 0 4px; letter-spacing: -0.01em; }
        .subtitle { color: var(--muted); margin: 0; }
        .spacer { flex: 1; }
        button {
          font: inherit;
          border: 1px solid var(--line);
          background: var(--panel);
          color: var(--text);
          border-radius: 7px;
          padding: 5px 11px;
          cursor: pointer;
        }
        button:hover:not(:disabled) { border-color: var(--accent); color: var(--accent); }
        button:disabled { opacity: 0.45; cursor: default; }
        button.primary {
          background: var(--accent);
          border-color: var(--accent);
          color: var(--accent-text);
        }
        button.primary:hover:not(:disabled) { color: var(--accent-text); filter: brightness(1.08); }
        main { max-width: 720px; margin: 0 auto; background: var(--panel); border: 1px solid var(--line); border-radius: 12px; overflow: hidden; }
        .row { display: flex; align-items: center; gap: 12px; padding: 12px 14px; border-top: 1px solid var(--line); }
        .row:first-child { border-top: 0; }
        .icon {
          width: 30px; height: 30px; flex: 0 0 30px;
          border-radius: 7px; background: var(--bg);
          display: flex; align-items: center; justify-content: center;
          font-size: 15px;
        }
        .info { min-width: 0; flex: 1; }
        .name { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .meta { color: var(--muted); font-size: 12px; margin-top: 2px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .copies { white-space: nowrap; }
        .copies span { display: block; font-size: 11px; color: var(--muted); }
        .copies span.unavailable { opacity: 0.5; text-decoration: line-through; }
        .empty, .loading { padding: 34px 20px; text-align: center; color: var(--muted); }
        .empty .title { color: var(--text); font-weight: 600; margin-bottom: 4px; font-size: 14px; }
        .note { max-width: 720px; margin: 14px auto 0; color: var(--muted); font-size: 12px; }
        .banner { max-width: 720px; margin: 0 auto 14px; border-radius: 9px; padding: 9px 12px; font-size: 12.5px; }
        .banner.warn { background: var(--warn); color: var(--warn-text); }
        .banner.good { background: var(--good); color: var(--good-text); }
        .hidden { display: none; }
        </style>
        </head>
        <body>
        <header>
          <div>
            <h1>Deleted Files</h1>
            <p class="subtitle">NeoDrop keeps a copy of every deleted file for \(retentionDays) days.</p>
          </div>
          <div class="spacer"></div>
          <button id="refresh">Refresh</button>
        </header>

        <div id="banner" class="banner hidden"></div>

        <main>
          <div id="list" class="loading">Loading…</div>
        </main>

        <p class="note">
          Restoring puts the file back in its original folder and it is mirrored again on the next sync.
          Files disappear from this list \(retentionDays) days after they were deleted, when their copies are cleaned up.
        </p>

        <script>
        var banner = document.getElementById('banner');
        var list = document.getElementById('list');
        var refresh = document.getElementById('refresh');

        function show(kind, message) {
          banner.className = 'banner ' + kind;
          banner.textContent = message;
          if (kind === 'good') { setTimeout(hide, 4000); }
        }
        function hide() { banner.className = 'banner hidden'; }

        function bytes(count) {
          var units = ['bytes', 'KB', 'MB', 'GB', 'TB'];
          var value = count || 0;
          var unit = 0;
          while (value >= 1024 && unit < units.length - 1) { value = value / 1024; unit++; }
          var text = (unit === 0) ? String(value) : value.toFixed(value < 10 ? 1 : 0);
          return text + ' ' + units[unit];
        }

        function when(iso) {
          var date = new Date(iso);
          if (isNaN(date)) { return ''; }
          var days = Math.round((date.getTime() - Date.now()) / 86400000);
          var relative;
          if (days === 0) { relative = 'today'; }
          else if (days === -1) { relative = 'yesterday'; }
          else if (days > 0) { relative = 'in ' + days + ' days'; }
          else { relative = Math.abs(days) + ' days ago'; }
          return date.toLocaleDateString() + ' · ' + relative;
        }

        function parent(ofPath) {
          var parts = ofPath.split('/');
          parts.pop();
          return parts.length ? parts.join('/') : '';
        }

        function name(ofPath) {
          return ofPath.split('/').pop();
        }

        function render(payload) {
          list.className = '';
          list.textContent = '';
          if (!payload.files || payload.files.length === 0) {
            var empty = document.createElement('div');
            empty.className = 'empty';
            var title = document.createElement('div');
            title.className = 'title';
            title.textContent = 'Nothing deleted';
            var hint = document.createElement('div');
            hint.textContent = 'Files you delete from a protected folder show up here for ' + payload.retentionDays + ' days.';
            empty.appendChild(title);
            empty.appendChild(hint);
            list.appendChild(empty);
            return;
          }
          payload.files.forEach(function (entry) {
            var row = document.createElement('div');
            row.className = 'row';

            var icon = document.createElement('div');
            icon.className = 'icon';
            icon.textContent = '\\u{1F5D1}';
            row.appendChild(icon);

            var info = document.createElement('div');
            info.className = 'info';
            var nameEl = document.createElement('div');
            nameEl.className = 'name';
            nameEl.textContent = name(entry.relativePath);
            nameEl.title = entry.relativePath;
            var metaEl = document.createElement('div');
            metaEl.className = 'meta';
            var where = parent(entry.relativePath);
            metaEl.textContent = (where ? where + ' · ' : '') + bytes(entry.size) + ' · deleted ' + when(entry.deletedAt) + ' · expires ' + when(entry.expiresAt);
            info.appendChild(nameEl);
            info.appendChild(metaEl);
            row.appendChild(info);

            var copies = document.createElement('div');
            copies.className = 'copies';
            (entry.copies || []).forEach(function (copy) {
              var line = document.createElement('span');
              line.textContent = copy.replicaName + (copy.available ? '' : ' (offline)');
              if (!copy.available) { line.className = 'unavailable'; }
              copies.appendChild(line);
            });
            row.appendChild(copies);

            var button = document.createElement('button');
            button.className = 'primary';
            button.textContent = 'Restore';
            button.disabled = !entry.restorable;
            if (!entry.restorable) { button.title = 'No destination is reachable right now'; }
            button.addEventListener('click', function () { restore(entry.relativePath, button); });
            row.appendChild(button);

            list.appendChild(row);
          });
        }

        function restore(relativePath, button) {
          button.disabled = true;
          button.textContent = 'Restoring…';
          hide();
          fetch('api/restore', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ relativePath: relativePath })
          }).then(function (response) {
            return response.json().catch(function () { return {}; }).then(function (body) {
              if (!response.ok) { throw new Error(body.error || ('Restore failed (' + response.status + ')')); }
              return body;
            });
          }).then(function (body) {
            show('good', 'Restored ' + name(relativePath) + ' to ' + body.restoredTo);
            load();
          }).catch(function (error) {
            show('warn', error.message);
            button.disabled = false;
            button.textContent = 'Restore';
          });
        }

        function load() {
          list.className = 'loading';
          list.textContent = 'Loading…';
          fetch('api/deletions').then(function (response) {
            if (!response.ok) { throw new Error('The deletion list could not be read (' + response.status + ')'); }
            return response.json();
          }).then(render).catch(function (error) {
            list.className = 'empty';
            list.textContent = error.message;
          });
        }

        refresh.addEventListener('click', load);
        load();
        </script>
        </body>
        </html>
        """
    }
}

import Foundation

/// The deleted-files page, served whole from `WebUIServer`.
///
/// One self-contained document: no external stylesheet, font, image or script, because the page
/// is loaded by a web view that has no business reaching the network. It talks to the same origin
/// through two relative endpoints, so the URL token never appears in the markup and the page keeps
/// working when the port changes next launch.
enum WebUIPage {
    /// The design tokens both pages share, so a colour is decided once. Everything here is inline:
    /// these pages are loaded by a web view that has no business reaching the network.
    static let tokens = """
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
        """

    /// Everything the page prints is user-visible text — a file name, a path, a machine name, a
    /// journal line — and none of it is markup. Escaping is the only thing standing between a file
    /// called `<img onerror=…>` and script execution inside an app-owned window.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    static func html(retentionDays: Int) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Deleted Files — NeoDrop</title>
        <style>
        \(tokens)
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
        .toolbar { max-width: 720px; margin: 0 auto 12px; display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
        .search { min-width: 180px; flex: 1; font: inherit; color: var(--text); background: var(--panel); border: 1px solid var(--line); border-radius: 7px; padding: 7px 10px; }
        .filters { display: flex; gap: 5px; }
        button.filter.active { background: var(--text); border-color: var(--text); color: var(--bg); }
        .count { color: var(--muted); font-size: 12px; margin: 0 0 8px; }
        .section { max-width: 720px; margin: 22px auto 8px; font-size: 16px; }
        .section-note { max-width: 720px; margin: 0 auto 10px; color: var(--muted); font-size: 12px; }
        .conflict-row { display: flex; align-items: center; gap: 12px; padding: 12px 14px; border-top: 1px solid var(--line); }
        .conflict-row .info { min-width: 0; flex: 1; }
        .danger { background: #b42318; border-color: #b42318; color: #fff; }
        .danger:hover:not(:disabled) { color: #fff; filter: brightness(1.08); }
        .version-details { margin-top: 5px; color: var(--muted); font-size: 11px; overflow-wrap: anywhere; }
        .version-details summary { cursor: pointer; }
        .version-details code { user-select: all; }
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
            <h1>Deleted Files &amp; Versions</h1>
            <p class="subtitle">Deleted files and the previous version of a replaced file, kept for \(retentionDays) days.</p>
          </div>
          <div class="spacer"></div>
          <button id="refresh">Refresh</button>
        </header>

        <div id="banner" class="banner hidden"></div>

        <div class="toolbar" role="search">
          <input id="search" class="search" type="search" placeholder="Search file or folder" aria-label="Search retained files and versions">
          <div class="filters" role="group" aria-label="Filter by why the version was kept">
            <button class="filter active" data-filter="all" aria-pressed="true">All</button>
            <button class="filter" data-filter="deleted" aria-pressed="false">Deleted</button>
            <button class="filter" data-filter="replaced" aria-pressed="false">Previous versions</button>
          </div>
        </div>
        <div id="count" class="count" role="status" aria-live="polite"></div>

        <main>
          <div id="list" class="loading">Loading…</div>
        </main>

        <h2 class="section">Files left on the share</h2>
        <p class="section-note">NeoDrop never replaces these automatically. Review the exact path and bytes before choosing to put the source file there instead. The share copy is kept for recovery first.</p>
        <main>
          <div id="foreign-list" class="loading">Checking for conflicts…</div>
        </main>

        <p class="note">
          Restoring puts the version back in its original folder and it is mirrored again on the next sync.
          Putting back a version that was replaced needs the version it replaces to be on a destination
          already, so the newer file is never lost — if it is not there yet, sync first.
          Files disappear from this list \(retentionDays) days after they left the mirror, when their copies are cleaned up.
        </p>

        <script>
        var banner = document.getElementById('banner');
        var list = document.getElementById('list');
        var foreignList = document.getElementById('foreign-list');
        var refresh = document.getElementById('refresh');
        var search = document.getElementById('search');
        var count = document.getElementById('count');
        var filterButtons = Array.prototype.slice.call(document.querySelectorAll('[data-filter]'));
        var allFiles = [];
        var activeFilter = 'all';
        var retentionDays = 30;

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

        function render() {
          list.className = '';
          list.textContent = '';
          var query = search.value.trim().toLocaleLowerCase();
          var files = allFiles.filter(function (entry) {
            var reasonMatches = activeFilter === 'all' || entry.reason === activeFilter;
            var textMatches = !query || entry.relativePath.toLocaleLowerCase().indexOf(query) !== -1;
            return reasonMatches && textMatches;
          });
          filterButtons.forEach(function (button) {
            var filter = button.getAttribute('data-filter');
            var matching = allFiles.filter(function (entry) {
              return filter === 'all' || entry.reason === filter;
            }).length;
            var label = filter === 'replaced' ? 'Previous versions' : (filter === 'deleted' ? 'Deleted' : 'All');
            button.textContent = label + ' (' + matching + ')';
            button.classList.toggle('active', activeFilter === filter);
            button.setAttribute('aria-pressed', activeFilter === filter ? 'true' : 'false');
          });
          count.textContent = files.length + ' of ' + allFiles.length + ' retained item(s)';
          if (allFiles.length === 0 || files.length === 0) {
            var empty = document.createElement('div');
            empty.className = 'empty';
            var title = document.createElement('div');
            title.className = 'title';
            title.textContent = allFiles.length === 0 ? 'Nothing here' : 'No matching versions';
            var hint = document.createElement('div');
            hint.textContent = allFiles.length === 0
              ? 'Deleted files and the versions NeoDrop replaces appear here for ' + retentionDays + ' days.'
              : 'Try a different name or choose another filter.';
            empty.appendChild(title);
            empty.appendChild(hint);
            list.appendChild(empty);
            return;
          }
          files.forEach(function (entry) {
            var row = document.createElement('div');
            row.className = 'row';

            var replaced = entry.reason === 'replaced';

            var icon = document.createElement('div');
            icon.className = 'icon';
            icon.textContent = replaced ? '↺' : '🗑';
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
            metaEl.textContent = (where ? where + ' · ' : '') + bytes(entry.size) + ' · ' + (replaced ? 'replaced ' : 'deleted ') + when(entry.deletedAt) + ' · expires ' + when(entry.expiresAt);
            var details = document.createElement('details');
            details.className = 'version-details';
            var summary = document.createElement('summary');
            summary.textContent = 'Version details';
            details.appendChild(summary);
            var digest = document.createElement('div');
            digest.textContent = 'SHA-256: ' + entry.sha256;
            digest.title = entry.sha256;
            details.appendChild(digest);
            var source = document.createElement('div');
            source.textContent = 'Restores to: ' + entry.sourcePath;
            details.appendChild(source);
            info.appendChild(nameEl);
            info.appendChild(metaEl);
            info.appendChild(details);
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
            else if (replaced) { button.title = 'Put this version back over the newer one'; }
            button.addEventListener('click', function () { restore(entry, button); });
            row.appendChild(button);

            list.appendChild(row);
          });
        }

        function restore(entry, button) {
          var relativePath = entry.relativePath;
          if (entry.reason === 'replaced' && !window.confirm(
            'Restore the previous version of ' + relativePath + '?\n\nThis replaces the current version in the source folder. NeoDrop checks that the current version is already on a mounted destination before continuing.'
          )) { return; }
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

        function renderForeign(files) {
          foreignList.className = '';
          foreignList.textContent = '';
          if (!files.length) {
            var empty = document.createElement('div');
            empty.className = 'empty';
            empty.textContent = 'No unresolved files on the shares.';
            foreignList.appendChild(empty);
            return;
          }
          files.forEach(function (entry) {
            var row = document.createElement('div');
            row.className = 'conflict-row';
            var info = document.createElement('div');
            info.className = 'info';
            var title = document.createElement('div');
            title.className = 'name';
            title.textContent = entry.relativePath;
            title.title = entry.absolutePath;
            var source = document.createElement('div');
            source.className = 'meta';
            source.textContent = entry.replicaName + ' · ' + (entry.sourcePath ? 'source: ' + entry.sourcePath : 'no matching source path');
            var theirs = document.createElement('div');
            theirs.className = 'meta';
            theirs.textContent = bytes(entry.size) + ' on share · SHA-256 ' + (entry.sha256 || 'unavailable');
            info.appendChild(title);
            info.appendChild(source);
            info.appendChild(theirs);
            row.appendChild(info);
            var button = document.createElement('button');
            button.className = 'danger';
            button.textContent = 'Replace with source…';
            button.disabled = !entry.replaceable;
            if (!entry.replaceable) { button.title = entry.unavailableReason || 'This conflict cannot be replaced right now'; }
            button.addEventListener('click', function () { replaceForeign(entry, button); });
            row.appendChild(button);
            foreignList.appendChild(row);
          });
        }

        function replaceForeign(entry, button) {
          if (!entry.replaceable || !entry.sha256) { return; }
          var answer = window.confirm(
            'Replace the file on ' + entry.replicaName + '?\\n\\n' + entry.relativePath + '\\n\\n' +
            'The share currently has ' + bytes(entry.size) + ' (SHA-256 ' + entry.sha256 + ').\\n' +
            'The source file will replace it. NeoDrop first keeps the share copy for ' + retentionDays + ' days in Deleted Files & Versions.'
          );
          if (!answer) { return; }
          button.disabled = true;
          button.textContent = 'Keeping copy…';
          fetch('api/foreign/replace', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              relativePath: entry.relativePath,
              replicaID: entry.replicaID,
              expectedSHA256: entry.sha256
            })
          }).then(function (response) {
            return response.json().catch(function () { return {}; }).then(function (body) {
              if (!response.ok) { throw new Error(body.error || ('Replace failed (' + response.status + ')')); }
              return body;
            });
          }).then(function () {
            show('good', 'Replaced ' + entry.relativePath + '; the share’s previous bytes are retained for recovery.');
            loadForeign();
            load();
          }).catch(function (error) {
            show('warn', error.message);
            button.disabled = false;
            button.textContent = 'Replace with source…';
          });
        }

        function loadForeign() {
          foreignList.className = 'loading';
          foreignList.textContent = 'Checking for conflicts…';
          fetch('api/foreign').then(function (response) {
            if (!response.ok) { throw new Error('The conflict list could not be read (' + response.status + ')'); }
            return response.json();
          }).then(function (payload) {
            renderForeign(payload.files || []);
          }).catch(function (error) {
            foreignList.className = 'empty';
            foreignList.textContent = error.message;
          });
        }

        function load() {
          list.className = 'loading';
          list.textContent = 'Loading…';
          fetch('api/deletions').then(function (response) {
            if (!response.ok) { throw new Error('The deletion list could not be read (' + response.status + ')'); }
            return response.json();
          }).then(function (payload) {
            allFiles = payload.files || [];
            retentionDays = payload.retentionDays || 30;
            render();
          }).catch(function (error) {
            list.className = 'empty';
            list.textContent = error.message;
          });
        }

        filterButtons.forEach(function (button) {
          button.addEventListener('click', function () {
            activeFilter = button.getAttribute('data-filter');
            render();
          });
        });
        search.addEventListener('input', render);
        refresh.addEventListener('click', function () { load(); loadForeign(); });
        load();
        loadForeign();
        </script>
        </body>
        </html>
        """
    }

    /// The file-status page: the answer to "is this file safe?" for one path.
    ///
    /// Rendered on the server instead of fetched by script, unlike the deleted-files page: the
    /// report is already computed when the window opens, there is nothing to act on, and a page
    /// with no JavaScript has nothing to go wrong. Every value it prints is escaped.
    static func statusHTML(for report: FileStatusReport) -> String {
        let rows = report.locations.map { location -> String in
            var lines = ""
            if let recorded = location.recorded {
                var facts = ["recorded by NeoDrop as \(escape(recorded.kind)) on \(date(recorded.at))"]
                if let verified = recorded.verifiedAt { facts.append("verified \(date(verified))") }
                if let machine = recorded.machineName { facts.append("published by \(escape(machine))") }
                if let expires = recorded.expiresAt { facts.append("recoverable until \(date(expires))") }
                if recorded.matches {
                    facts.append("size and date match the record")
                } else if location.present {
                    facts.append("does NOT match the record — ask Verify & Repair to check the bytes")
                }
                lines = "<div class=\"detail\">\(facts.joined(separator: " · "))</div>"
            }
            return """
                <div class="row">
                  <div class="info">
                    <div class="name">\(escape(location.role.label)) — \(escape(location.name))\(location.present ? "" : " <span class=\"missing\">not there now</span>")</div>
                    <div class="path">\(escape(location.absolutePath))</div>
                    <div class="detail">\(escape(location.note))</div>
                    \(lines)
                  </div>
                </div>
                """
        }.joined()

        let history = report.history.isEmpty
            ? "<div class=\"row\"><div class=\"info\"><div class=\"detail\">No two-way folder has published a change to this path.</div></div></div>"
            : report.history.map { entry in
                """
                <div class="row">
                  <div class="info">
                    <div class="name">\(escape(entry.kind))d by \(escape(entry.machineName))</div>
                    <div class="detail">\(date(entry.at)) · \(bytes(entry.size)) · \(escape(String(entry.sha256.prefix(12))))…</div>
                  </div>
                </div>
                """
            }.joined()

        let badge = report.covered ? "" : "<div class=\"banner warn\">Not in any NeoDrop folder.</div>"

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>File Status — NeoDrop</title>
        <style>
        \(tokens)
        * { box-sizing: border-box; }
        body {
          margin: 0;
          padding: 22px 20px 40px;
          background: var(--bg);
          color: var(--text);
          font: 13px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
        }
        header, main, .banner, .note { max-width: 720px; margin: 0 auto; }
        h1 { font-size: 21px; line-height: 1.2; margin: 0 0 4px; letter-spacing: -0.01em; }
        .path { color: var(--muted); font-size: 12px; word-break: break-all; margin: 0; }
        .summary { margin: 14px auto 0; padding: 11px 13px; background: var(--panel); border: 1px solid var(--line); border-radius: 10px; }
        .banner { margin: 12px auto 0; border-radius: 9px; padding: 9px 12px; font-size: 12.5px; }
        .banner.warn { background: var(--warn); color: var(--warn-text); }
        section { max-width: 720px; margin: 18px auto 0; }
        h2 { font-size: 12px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); margin: 0 0 6px 2px; }
        main, .list { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; overflow: hidden; }
        .row { padding: 11px 14px; border-top: 1px solid var(--line); }
        .row:first-child { border-top: 0; }
        .name { font-weight: 600; }
        .name .missing { font-weight: 400; color: var(--muted); font-size: 11px; text-transform: uppercase; letter-spacing: 0.04em; }
        .detail { color: var(--muted); font-size: 12px; margin-top: 3px; }
        .note { margin-top: 16px; color: var(--muted); font-size: 12px; }
        </style>
        </head>
        <body>
        <header>
          <h1>File Status</h1>
          <p class="path">\(escape(report.path))</p>
        </header>
        \(badge)
        <p class="summary">\(escape(report.summary))</p>

        <section>
          <h2>Where this file is</h2>
          <main>\(rows.isEmpty ? "<div class=\"row\"><div class=\"info\"><div class=\"detail\">NeoDrop has nothing to say about this path.</div></div></div>" : rows)</main>
        </section>

        <section>
          <h2>History in the two-way folders</h2>
          <div class="list">\(history)</div>
        </section>

        <p class="note">
          A copy is counted here when NeoDrop's records and the file system agree. The bytes
          themselves are checked by Verify &amp; Repair, which is slower because it reads every file.
        </p>
        </body>
        </html>
        """
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func date(_ value: Date) -> String { stamp.string(from: value) }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

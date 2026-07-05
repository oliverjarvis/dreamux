require.config({ paths: { vs: 'app-monaco://app/vs' } });

// Monaco runs language services in web workers. Under a custom scheme the
// worker script can't be fetched cross-origin, so route worker creation
// through a data: URL that importScripts the real worker (standard
// Monaco offline workaround).
self.MonacoEnvironment = {
  getWorkerUrl: function (moduleId, label) {
    var base = 'app-monaco://app/vs';
    var proxy = 'self.MonacoEnvironment = { baseUrl: "' + base + '/" };' +
      'importScripts("' + base + '/base/worker/workerMain.js");';
    return 'data:text/javascript;charset=utf-8,' + encodeURIComponent(proxy);
  }
};

function post(msg) { window.webkit.messageHandlers.bridge.postMessage(msg); }

require(['vs/editor/editor.main'], function () {
  // Monaco ships ~80 languages but not TOML; register a small Monarch
  // tokenizer so run.toml / Cargo.toml / pyproject.toml highlight.
  monaco.languages.register({ id: 'toml', extensions: ['.toml'] });
  monaco.languages.setLanguageConfiguration('toml', {
    comments: { lineComment: '#' },
    brackets: [['[', ']'], ['{', '}']],
  });
  monaco.languages.setMonarchTokensProvider('toml', {
    tokenizer: {
      root: [
        [/^\s*\[\[?[^\]]*\]\]?/, 'keyword'],            // [table] / [[array of tables]]
        [/^\s*[A-Za-z0-9_"'.-]+(?=\s*=)/, 'variable'],  // key =
        [/#.*$/, 'comment'],
        [/"""/, 'string', '@tripleString'],
        [/"/, 'string', '@string'],
        [/'''/, 'string', '@tripleLiteral'],
        [/'/, 'string', '@literalString'],
        [/\b(true|false)\b/, 'constant'],
        // Dates before numbers so 2026-07-02 isn't three numbers.
        [/\d{4}-\d{2}-\d{2}([Tt ]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})?)?/, 'number'],
        [/\d{2}:\d{2}:\d{2}(\.\d+)?/, 'number'],
        [/[+-]?(0x[0-9A-Fa-f_]+|0o[0-7_]+|0b[01_]+|inf|nan|\d[\d_]*(\.[\d_]+)?([eE][+-]?\d+)?)/, 'number'],
        [/[,={}\[\]]/, 'delimiter'],
      ],
      string: [
        [/[^"\\]+/, 'string'],
        [/\\./, 'string.escape'],
        [/"/, 'string', '@pop'],
      ],
      tripleString: [
        [/"""/, 'string', '@pop'],
        [/\\./, 'string.escape'],
        [/./, 'string'],
      ],
      literalString: [
        [/[^']+/, 'string'],
        [/'/, 'string', '@pop'],
      ],
      tripleLiteral: [
        [/'''/, 'string', '@pop'],
        [/./, 'string'],
      ],
    },
  });

  // The vendored registry misses a few extensions we care about:
  // shell omits .zsh, markdown omits .mdx. Registering the same id
  // again merges the extra extensions into the existing language.
  monaco.languages.register({ id: 'shell', extensions: ['.zsh'] });
  monaco.languages.register({ id: 'markdown', extensions: ['.mdx'] });

  var editor = monaco.editor.create(document.getElementById('container'), {
    value: '',
    language: 'plaintext',
    theme: 'vs',
    automaticLayout: true,
    minimap: { enabled: true },
    fontSize: 14
  });

  editor.onDidChangeModelContent(function () {
    post({ type: 'dirty', value: true });
  });

  editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, function () {
    post({ type: 'save', text: editor.getValue() });
  });

  // Resolve a file extension against every language Monaco knows
  // (built-ins plus anything registered above). Case-insensitive;
  // unknown extensions fall back to plaintext.
  function languageForExtension(ext) {
    if (!ext) return 'plaintext';
    var dot = '.' + String(ext).toLowerCase();
    var langs = monaco.languages.getLanguages();
    for (var i = 0; i < langs.length; i++) {
      var exts = langs[i].extensions || [];
      for (var j = 0; j < exts.length; j++) {
        if (exts[j].toLowerCase() === dot) return langs[i].id;
      }
    }
    return 'plaintext';
  }

  // Swift → editor: install a file's contents/extension/theme.
  window.__setContents = function (text, ext, theme) {
    monaco.editor.setTheme(theme);
    editor.setModel(monaco.editor.createModel(text, languageForExtension(ext)));
    post({ type: 'dirty', value: false });
  };

  // Read-only side-by-side diff. First call disposes the standard
  // editor and replaces it with a diff editor in the same container;
  // later calls just swap models. ext drives language inference the
  // same way __setContents does (languageForExtension, above).
  var diffEditor = null;
  window.__setDiff = function (originalText, modifiedText, ext, theme) {
    var language = languageForExtension(ext);
    if (!diffEditor) {
      if (editor) { editor.dispose(); editor = null; }
      diffEditor = monaco.editor.createDiffEditor(
        document.getElementById('container'), {
          automaticLayout: true,
          readOnly: true,
          originalEditable: false,
          renderSideBySide: true,
          minimap: { enabled: false },
          fontSize: 14,
        });
    }
    monaco.editor.setTheme(theme);
    var original = monaco.editor.createModel(originalText, language);
    var modified = monaco.editor.createModel(modifiedText, language);
    var old = diffEditor.getModel();
    diffEditor.setModel({ original: original, modified: modified });
    if (old) { old.original.dispose(); old.modified.dispose(); }
  };

  // Editor → Swift pull: the rendered-markdown toggle reads the live
  // buffer without waiting for a save.
  window.__getValue = function () { return editor.getValue(); };

  // Swift → editor: jump to a 1-based line (sidebar phase/task rows
  // open a plan at the clicked section).
  window.__revealLine = function (line) {
    editor.revealLineInCenter(line);
    editor.setPosition({ lineNumber: line, column: 1 });
    editor.focus();
  };

  post({ type: 'ready' });
});

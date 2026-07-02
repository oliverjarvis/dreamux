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
  var editor = monaco.editor.create(document.getElementById('container'), {
    value: '',
    language: 'plaintext',
    theme: 'vs',
    automaticLayout: true,
    minimap: { enabled: true }
  });

  editor.onDidChangeModelContent(function () {
    post({ type: 'dirty', value: true });
  });

  editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, function () {
    post({ type: 'save', text: editor.getValue() });
  });

  // Swift → editor: install a file's contents/language/theme.
  window.__setContents = function (text, language, theme) {
    monaco.editor.setTheme(theme);
    editor.setModel(monaco.editor.createModel(text, language));
    post({ type: 'dirty', value: false });
  };

  post({ type: 'ready' });
});

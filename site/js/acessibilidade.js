// Conecta Cidadão - ajustes de leitura (tamanho da letra e alto contraste).
// O site funciona normalmente sem JavaScript; isto é apenas um recurso extra.
(function () {
  'use strict';
  var raiz = document.documentElement;
  var CHAVE = 'conecta-preferencias';
  var pref = { letra: 0, contraste: false };

  try {
    var salvo = JSON.parse(localStorage.getItem(CHAVE));
    if (salvo) { pref.letra = salvo.letra || 0; pref.contraste = !!salvo.contraste; }
  } catch (e) { /* sem armazenamento: usa o padrão */ }

  function aplicar() {
    raiz.setAttribute('data-letra', String(pref.letra));
    if (pref.contraste) { raiz.setAttribute('data-contraste', 'alto'); } else { raiz.removeAttribute('data-contraste'); }
    var botao = document.getElementById('contraste');
    if (botao) { botao.setAttribute('aria-pressed', pref.contraste ? 'true' : 'false'); }
    try { localStorage.setItem(CHAVE, JSON.stringify(pref)); } catch (e) { /* ignora */ }
  }

  aplicar();

  document.addEventListener('DOMContentLoaded', function () {
    document.getElementById('letra-maior').addEventListener('click', function () { pref.letra = Math.min(2, pref.letra + 1); aplicar(); });
    document.getElementById('letra-menor').addEventListener('click', function () { pref.letra = Math.max(0, pref.letra - 1); aplicar(); });
    document.getElementById('contraste').addEventListener('click', function () { pref.contraste = !pref.contraste; aplicar(); });
    aplicar();
  });
})();

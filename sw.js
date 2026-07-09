/* Service worker de Viaje Amieva: funciona 100% sin conexion (la casa no tiene wifi). */
var CACHE = 'viaje-amieva-v1';
var CORE = [
  './',
  './index.html',
  './manifest.json',
  './icon-192.png',
  './icon-512.png'
];
var CDN = [
  'https://www.gstatic.com/firebasejs/10.12.5/firebase-app-compat.js',
  'https://www.gstatic.com/firebasejs/10.12.5/firebase-database-compat.js'
];

self.addEventListener('install', function(e){
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE).then(function(c){
    var p = c.addAll(CORE.map(function(u){ return new Request(u, {cache:'reload'}); })).catch(function(){});
    // CDN de Firebase (cross-origin, no-cors): mejor esfuerzo
    var q = Promise.all(CDN.map(function(u){
      return fetch(new Request(u, {mode:'no-cors'})).then(function(r){ return c.put(u, r); }).catch(function(){});
    }));
    return Promise.all([p, q]);
  }));
});

self.addEventListener('activate', function(e){
  e.waitUntil(caches.keys().then(function(keys){
    return Promise.all(keys.filter(function(k){ return k !== CACHE; }).map(function(k){ return caches.delete(k); }));
  }).then(function(){ return self.clients.claim(); }));
});

self.addEventListener('fetch', function(e){
  var req = e.request;
  if(req.method !== 'GET'){ return; }
  var url;
  try { url = new URL(req.url); } catch(err) { return; }
  // Trafico de Firebase Realtime DB: siempre red, nunca cache (offline falla en silencio)
  if(url.hostname.indexOf('firebasedatabase.app') >= 0 || url.hostname.indexOf('firebaseio.com') >= 0) { return; }
  // Navegacion (abrir la app): sirve la cache al instante y actualiza por detras (SWR)
  if(req.mode === 'navigate'){
    e.respondWith(caches.open(CACHE).then(function(c){
      return c.match('./index.html').then(function(cached){
        var net = fetch(req).then(function(resp){ try{ c.put('./index.html', resp.clone()); }catch(e){} return resp; }).catch(function(){ return cached; });
        return cached || net;
      });
    }));
    return;
  }
  // Resto (iconos, manifest, scripts de Firebase): cache primero, red de respaldo
  e.respondWith(caches.match(req).then(function(cached){
    if(cached){ return cached; }
    return fetch(req).then(function(resp){
      try{ var copy = resp.clone(); caches.open(CACHE).then(function(c){ c.put(req, copy); }); }catch(e){}
      return resp;
    }).catch(function(){ return cached; });
  }));
});

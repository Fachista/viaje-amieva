#Requires -Version 5.1
<#
  ViajeAmieva.ps1 - Panel del viaje a Amieva (Asturias)
  - Baja precios reales de Gasolina 95 (API oficial Ministerio) en un radio alrededor
    de cada parada de la ruta y calcula si compensa desviarse a una mas barata.
  - Calcula autonomia del Nissan Micra y coste por tramo.
  - Genera index.html (gasolina la pone uno y se reparte, comida aparte, maleta editable).

  Uso:
    .\ViajeAmieva.ps1            -> baja precios, genera el panel y lo abre
    .\ViajeAmieva.ps1 -NoApi     -> sin internet, panel sin precios
    .\ViajeAmieva.ps1 -NoOpen    -> genera el panel pero no lo abre

  Lo mas comodo: doble clic en "Abrir panel.bat".
  Los datos editables estan en datos.json.
#>
[CmdletBinding()]
param(
  [switch]$NoApi,
  [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataPath = Join-Path $Root 'datos.json'
$HtmlPath = Join-Path $Root 'index.html'

[Net.ServicePointManager]::SecurityProtocol = `
  [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
$INV = [System.Globalization.CultureInfo]::InvariantCulture

# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------
function Remove-Diacritics {
  param([string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  $n = $Text.Normalize([Text.NormalizationForm]::FormD)
  $sb = New-Object Text.StringBuilder
  foreach ($c in $n.ToCharArray()) {
    if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne `
        [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($c) }
  }
  return $sb.ToString().Normalize([Text.NormalizationForm]::FormC)
}

function Get-Prop {
  param([object]$Obj, [string]$Pattern)
  $target = (Remove-Diacritics $Pattern).ToLowerInvariant() -replace '[^a-z0-9]', ''
  foreach ($p in $Obj.PSObject.Properties) {
    $norm = (Remove-Diacritics $p.Name).ToLowerInvariant() -replace '[^a-z0-9]', ''
    if ($norm -like "*$target*") { return $p.Value }
  }
  return $null
}

function ConvertTo-Price {
  param($Raw)
  if ($null -eq $Raw) { return $null }
  $s = ([string]$Raw).Trim()
  if ($s -eq '' -or $s -eq '0' -or $s -eq '0,000') { return $null }
  if ($s.Contains(',')) { $s = ($s -replace '\.', '') -replace ',', '.' }
  $val = 0.0
  if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, $INV, [ref]$val)) {
    if ($val -le 0) { return $null }
    return [math]::Round($val, 3)
  }
  return $null
}

function ConvertTo-Coord {
  param($Raw)
  if ($null -eq $Raw) { return $null }
  $s = ([string]$Raw).Trim() -replace ',', '.'
  $val = 0.0
  if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, $INV, [ref]$val)) { return $val }
  return $null
}

function Get-DistanceKm {
  param([double]$Lat1,[double]$Lon1,[double]$Lat2,[double]$Lon2)
  $r = 6371.0
  $dLat = ($Lat2 - $Lat1) * [math]::PI / 180
  $dLon = ($Lon2 - $Lon1) * [math]::PI / 180
  $a = [math]::Sin($dLat/2)*[math]::Sin($dLat/2) +
       [math]::Cos($Lat1*[math]::PI/180)*[math]::Cos($Lat2*[math]::PI/180)*[math]::Sin($dLon/2)*[math]::Sin($dLon/2)
  return $r * 2 * [math]::Atan2([math]::Sqrt($a), [math]::Sqrt(1-$a))
}

function HtmlEnc { param([string]$s) if ($null -eq $s) { return '' } return [System.Net.WebUtility]::HtmlEncode($s) }

function Invoke-FuelApi {
  param([string]$Url, [int]$Retries = 3)
  $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) ViajeAmieva/1.0'
  $delay = 4
  for ($i = 1; $i -le $Retries; $i++) {
    try {
      $resp = Invoke-WebRequest -Uri $Url -Headers @{ 'User-Agent'=$ua; 'Accept'='application/json' } `
        -TimeoutSec 45 -UseBasicParsing
      return ($resp.Content | ConvertFrom-Json)
    } catch {
      Write-Host "  API intento $i/$Retries fallo: $($_.Exception.Message)" -ForegroundColor Yellow
      if ($i -lt $Retries) { Start-Sleep -Seconds $delay; $delay *= 2 }
    }
  }
  throw "API no disponible: $Url"
}

# ---------------------------------------------------------------------------
# Tiempo (Open-Meteo, sin clave)
# ---------------------------------------------------------------------------
function Get-Weather {
  param($Data)
  $result = @{}
  if (-not $Data.PSObject.Properties['casaCoord']) { return $result }
  try {
    $lat = ([double]$Data.casaCoord.lat).ToString('0.####',$INV)
    $lon = ([double]$Data.casaCoord.lon).ToString('0.####',$INV)
    $url = "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=Europe%2FMadrid&forecast_days=16"
    Write-Host "Consultando el tiempo en Amieva..." -ForegroundColor Gray
    $w = Invoke-FuelApi -Url $url -Retries 2
    if ($w.PSObject.Properties['daily']) {
      $t = $w.daily.time
      for ($i=0; $i -lt $t.Count; $i++) {
        $result[[string]$t[$i]] = [pscustomobject]@{
          Code = [int]$w.daily.weather_code[$i]
          TMax = [int][math]::Round([double]$w.daily.temperature_2m_max[$i])
          TMin = [int][math]::Round([double]$w.daily.temperature_2m_min[$i])
          Rain = [int]$w.daily.precipitation_probability_max[$i]
        }
      }
    }
  } catch { Write-Host "  Sin datos de tiempo: $($_.Exception.Message)" -ForegroundColor Yellow }
  return $result
}

function Get-WeatherIcon {
  param([int]$Code)
  if ($Code -eq 0) { return @('&#9728;&#65039;','Despejado') }
  if ($Code -in 1,2,3) { return @('&#9925;','Nubes') }
  if ($Code -in 45,48) { return @('&#127787;&#65039;','Niebla') }
  if ($Code -in 51,53,55,56,57) { return @('&#127782;&#65039;','Llovizna') }
  if ($Code -in 61,63,65,66,67) { return @('&#127783;&#65039;','Lluvia') }
  if ($Code -in 71,73,75,77) { return @('&#10052;&#65039;','Nieve') }
  if ($Code -in 80,81,82) { return @('&#127782;&#65039;','Chubascos') }
  if ($Code -in 95,96,99) { return @('&#9928;&#65039;','Tormenta') }
  return @('&#127780;&#65039;','-')
}

# ---------------------------------------------------------------------------
# Gasolineras por parada (radio + distancia)
# ---------------------------------------------------------------------------
function Get-RouteStations {
  param($Data)
  $base = 'https://sedeaplicaciones.minetur.gob.es/ServiciosRESTCarburantes/' +
          'PreciosCarburantes/EstacionesTerrestres/FiltroProvincia/'
  $cache = @{}
  $result = @()
  $fecha = ''
  foreach ($p in $Data.paradas) {
    Write-Host "Consultando gasolineras: $($p.nombre)..." -ForegroundColor Gray
    if (-not $cache.ContainsKey([string]$p.prov)) {
      try {
        $api = Invoke-FuelApi -Url ($base + $p.prov)
        if (-not $fecha -and $api.PSObject.Properties['Fecha']) { $fecha = [string]$api.Fecha }
        $cache[[string]$p.prov] = $api.ListaEESSPrecio
      } catch {
        Write-Host "  Sin datos provincia $($p.prov): $($_.Exception.Message)" -ForegroundColor Yellow
        $cache[[string]$p.prov] = @()
      }
    }
    $clat = [double]$p.lat; $clon = [double]$p.lon; $radio = [double]$p.radioKm
    $stations = @()
    foreach ($e in $cache[[string]$p.prov]) {
      $price = ConvertTo-Price (Get-Prop $e 'Gasolina 95 E5')
      if ($null -eq $price) { continue }
      $lat = ConvertTo-Coord (Get-Prop $e 'Latitud')
      $lon = ConvertTo-Coord (Get-Prop $e 'Longitud')
      if ($null -eq $lat -or $null -eq $lon) { continue }
      $dist = [math]::Round((Get-DistanceKm $clat $clon $lat $lon), 1)
      if ($dist -gt $radio) { continue }
      $stations += [pscustomobject]@{
        Rotulo    = [string](Get-Prop $e 'Rotulo')
        Direccion = [string](Get-Prop $e 'Direccion')
        Municipio = [string](Get-Prop $e 'Municipio')
        Precio    = $price
        Lat       = $lat
        Lon       = $lon
        Dist      = $dist
      }
    }
    $stations = @($stations | Sort-Object Precio, Dist)
    $result += [pscustomobject]@{ Nombre = $p.nombre; Estaciones = $stations }
  }
  return [pscustomobject]@{ Fecha = $fecha; Paradas = $result }
}

# Economia del desvio: devuelve la parada con estacion recomendada y lista evaluada
function Resolve-Economics {
  param($Parada, [double]$Consumo, [double]$Litros)
  $est = @($Parada.Estaciones)
  if ($est.Count -eq 0) { return [pscustomobject]@{ Nombre=$Parada.Nombre; Reco=$null; Lista=@(); RefPrecio=$null } }

  # baseline = la mas barata "de paso" (<=3 km); si no, la mas cercana
  $cerca = @($est | Where-Object { $_.Dist -le 3 } | Sort-Object Precio)
  $base = if ($cerca.Count -gt 0) { $cerca[0] } else { ($est | Sort-Object Dist)[0] }
  $refPrecio = [double]$base.Precio
  $refDist   = [double]$base.Dist

  $eval = @()
  foreach ($s in $est) {
    $extraKm = [math]::Max(0, [double]$s.Dist - $refDist)
    $detour  = 2 * $extraKm * $Consumo / 100 * [double]$s.Precio
    $bruto   = ($refPrecio - [double]$s.Precio) * $Litros
    $neto    = [math]::Round($bruto - $detour, 2)
    $eval += [pscustomobject]@{
      Rotulo=$s.Rotulo; Direccion=$s.Direccion; Municipio=$s.Municipio; Precio=[double]$s.Precio
      Lat=$s.Lat; Lon=$s.Lon; Dist=[double]$s.Dist; ExtraKm=[math]::Round($extraKm,1); Neto=$neto
    }
  }
  # recomendada = mayor ahorro neto, pero solo desvios razonables (<=12 km extra)
  # las mas lejanas siguen listadas en "ver otras", pero no se recomiendan
  $cand = @($eval | Where-Object { $_.ExtraKm -le 12 })
  if ($cand.Count -eq 0) { $cand = $eval }
  $reco = $cand | Sort-Object Neto -Descending | Select-Object -First 1
  $lista = @($eval | Sort-Object Neto -Descending)
  return [pscustomobject]@{ Nombre=$Parada.Nombre; Reco=$reco; Lista=$lista; RefPrecio=$refPrecio }
}

# ---------------------------------------------------------------------------
# HTML
# ---------------------------------------------------------------------------
function Build-Html {
  param($Data, $Route, [bool]$ApiOk, $Weather = @{})

  $consumo  = [double]$Data.coche.consumoL100
  $deposito = [double]$Data.coche.depositoL
  $litros   = [double]$Data.litrosPorRepostaje
  $autonomia = if ($consumo -gt 0) { [int][math]::Round($deposito / $consumo * 100) } else { 0 }

  # economia por parada
  $ecos = @()
  foreach ($p in $Route.Paradas) { $ecos += (Resolve-Economics -Parada $p -Consumo $consumo -Litros $litros) }

  $allPrices = @()
  foreach ($eco in $ecos) { if ($eco.Reco) { $allPrices += [double]$eco.Reco.Precio } }
  $refPrice = if ($allPrices.Count -gt 0) { ($allPrices | Measure-Object -Minimum).Minimum } else { [double]$Data.precioGasolinaFallback }

  # cuenta atras
  $diasTxt = ''
  try {
    $inicio = [datetime]::ParseExact([string]$Data.fechaInicio,'yyyy-MM-dd',$INV)
    $d = [int][math]::Ceiling(($inicio.Date - (Get-Date).Date).TotalDays)
    if ($d -gt 1)      { $diasTxt = "Faltan $d dias" }
    elseif ($d -eq 1)  { $diasTxt = "Manana salimos!" }
    elseif ($d -eq 0)  { $diasTxt = "Hoy empieza el viaje!" }
    elseif ($d -ge -7) { $diasTxt = "De viaje" }
    else               { $diasTxt = "Viaje terminado" }
  } catch { $diasTxt = '' }

  # tiempo: mapea cada dia del viaje a su prevision (si esta disponible)
  $weatherHtml = New-Object Text.StringBuilder
  $hayTiempo = $false
  try {
    $inicioW = [datetime]::ParseExact([string]$Data.fechaInicio,'yyyy-MM-dd',$INV)
    $dias3 = @('Dom','Lun','Mar','Mie','Jue','Vie','Sab')
    $diaNum = @('','dom','lun','mar','mie','jue','vie','sab')
    for ($i = 0; $i -lt $Data.dias.Count; $i++) {
      $fd = $inicioW.AddDays($i)
      $key = $fd.ToString('yyyy-MM-dd')
      $etq = $dias3[[int]$fd.DayOfWeek] + ' ' + $fd.Day
      if ($Weather.ContainsKey($key)) {
        $hayTiempo = $true
        $wi = $Weather[$key]
        $ico = (Get-WeatherIcon $wi.Code)
        [void]$weatherHtml.Append("<div class='wday'><div class='wd-f'>$etq</div><div class='wd-i'>$($ico[0])</div><div class='wd-t'>$($wi.TMax)&deg; / $($wi.TMin)&deg;</div><div class='wd-r'>&#127783;&#65039; $($wi.Rain)%</div></div>")
      } else {
        [void]$weatherHtml.Append("<div class='wday off'><div class='wd-f'>$etq</div><div class='wd-i'>&middot;&middot;&middot;</div><div class='wd-t muted' style='font-size:11px'>lejos</div></div>")
      }
    }
  } catch { }

  # sitios con enlaces a Maps
  $sitiosHtml = New-Object Text.StringBuilder
  if ($Data.PSObject.Properties['sitios']) {
    foreach ($s in $Data.sitios) {
      $ll = "$(([double]$s.lat).ToString('0.######',$INV)),$(([double]$s.lon).ToString('0.######',$INV))"
      $mm = "https://www.google.com/maps/search/?api=1&query=$ll"
      [void]$sitiosHtml.Append("<a class='sitio' href='$mm' target='_blank'>&#128205; $(HtmlEnc $s.nombre)<span>&rsaquo;</span></a>")
    }
  }

  # tramos ida
  $kmIda = 0.0
  $tramosHtml = New-Object Text.StringBuilder
  foreach ($t in $Data.tramosIda) {
    $km = [double]$t.km; $kmIda += $km
    $litrosT = [math]::Round($km * $consumo / 100, 1)
    $coste  = [math]::Round($litrosT * $refPrice, 2)
    [void]$tramosHtml.Append("<tr><td>$(HtmlEnc $t.de) &rarr; $(HtmlEnc $t.a)</td><td class='num'>$($km.ToString('0',$INV))</td><td class='num'>$($litrosT.ToString('0.0',$INV))</td><td class='num'>$($coste.ToString('0.00',$INV)) &euro;</td></tr>")
  }
  $litrosIda = [math]::Round($kmIda * $consumo / 100, 1)
  $costeIda  = [math]::Round($litrosIda * $refPrice, 2)
  $costeIdaVuelta = [math]::Round($costeIda * 2, 2)

  # gasolineras (server-side, con recomendacion y "ver otras")
  $gasHtml = New-Object Text.StringBuilder
  $mejorGlobal = $null
  foreach ($eco in $ecos) {
    [void]$gasHtml.Append("<div class='zona'>")
    if (-not $eco.Reco) {
      [void]$gasHtml.Append("<div class='zona-n'>$(HtmlEnc $eco.Nombre)</div><div class='muted'>Sin gasolineras con datos en la zona ahora.</div></div>")
      continue
    }
    $r = $eco.Reco
    if ($null -eq $mejorGlobal -or [double]$r.Precio -lt [double]$mejorGlobal.Precio) { $mejorGlobal = $r }
    $maps = "https://www.google.com/maps/search/?api=1&query=$($r.Lat.ToString('0.######',$INV)),$($r.Lon.ToString('0.######',$INV))"
    $desvio = if ($r.ExtraKm -le 0.6) { "de paso" } else { "+$($r.ExtraKm.ToString('0.#',$INV)) km de desvio" }
    $ahorro = if ($r.Neto -gt 0.3 -and $r.ExtraKm -gt 0.6) { " &middot; ahorras ~$($r.Neto.ToString('0.0',$INV)) &euro; (en $($litros.ToString('0',$INV)) L)" } else { "" }
    [void]$gasHtml.Append("<div class='zona-n'>$(HtmlEnc $eco.Nombre)</div>")
    [void]$gasHtml.Append("<div class='zona-top'>")
    [void]$gasHtml.Append("<div><div class='zona-sub'><b>$(HtmlEnc $r.Rotulo)</b> &middot; $(HtmlEnc $r.Municipio)</div><div class='zona-meta'>$desvio$ahorro</div><a class='maplink' href='$maps' target='_blank'>Abrir en Maps &rsaquo;</a></div>")
    [void]$gasHtml.Append("<div class='precio'>$(([double]$r.Precio).ToString('0.000',$INV))<span>&euro;/L</span></div>")
    [void]$gasHtml.Append("</div>")
    $otras = @($eco.Lista | Where-Object { -not ($_.Rotulo -eq $r.Rotulo -and $_.Dist -eq $r.Dist -and $_.Precio -eq $r.Precio) } | Select-Object -First 5)
    if ($otras.Count -gt 0) {
      [void]$gasHtml.Append("<button class='vermas' onclick='toggleNext(this)'>Ver otras $($otras.Count)</button>")
      [void]$gasHtml.Append("<div class='mas'><table>")
      foreach ($s in $otras) {
        $dtxt = if ($s.ExtraKm -le 0.6) { "de paso" } else { "+$($s.ExtraKm.ToString('0.#',$INV)) km" }
        $ntxt = if ($s.ExtraKm -le 0.6) { "" } elseif ($s.Neto -gt 0.3) { "<span class='gd'>ahorra ~$($s.Neto.ToString('0.0',$INV)) &euro;</span>" } elseif ($s.Neto -lt -0.3) { "<span class='bad'>no compensa</span>" } else { "<span class='muted'>casi igual</span>" }
        $m2 = "https://www.google.com/maps/search/?api=1&query=$($s.Lat.ToString('0.######',$INV)),$($s.Lon.ToString('0.######',$INV))"
        [void]$gasHtml.Append("<tr><td><a class='maplink' href='$m2' target='_blank'>$(HtmlEnc $s.Rotulo)</a><div class='dir'>$(HtmlEnc $s.Municipio) &middot; $dtxt $ntxt</div></td><td class='num'>$(([double]$s.Precio).ToString('0.000',$INV))</td></tr>")
      }
      [void]$gasHtml.Append("</table></div>")
    }
    [void]$gasHtml.Append("</div>")
  }
  $cheapTxt = if ($mejorGlobal) {
    "<b>$(HtmlEnc $mejorGlobal.Rotulo)</b> en $(HtmlEnc $mejorGlobal.Municipio) &middot; <b>$(([double]$mejorGlobal.Precio).ToString('0.000',$INV)) &euro;/L</b>"
  } else { "Sin precios ahora mismo (revisa la conexion)." }

  # dias (acordeon)
  $diasHtml = New-Object Text.StringBuilder
  $iDia = 0
  foreach ($dd in $Data.dias) {
    $iDia++
    $teaser = ([string]$dd.manana -split '\. ')[0]
    if ($teaser.Length -gt 80) { $teaser = $teaser.Substring(0,77) + '...' }
    $open = if ($iDia -eq 1) { ' open' } else { '' }
    [void]$diasHtml.Append("<div class='dia$open'>")
    [void]$diasHtml.Append("<button class='dia-h' onclick='toggleDia(this)'><div><div class='dia-f'>$(HtmlEnc $dd.fecha)</div><div class='dia-t'>$(HtmlEnc $teaser)</div></div><span class='chev'>&rsaquo;</span></button>")
    [void]$diasHtml.Append("<div class='dia-b'>")
    [void]$diasHtml.Append("<p><span class='lab'>Manana</span> <span class='ed' data-k='d$iDia-m'>$(HtmlEnc $dd.manana)</span></p>")
    [void]$diasHtml.Append("<p><span class='lab'>Tarde</span> <span class='ed' data-k='d$iDia-t'>$(HtmlEnc $dd.tarde)</span></p>")
    [void]$diasHtml.Append("<p><span class='lab'>Noche</span> <span class='ed' data-k='d$iDia-n'>$(HtmlEnc $dd.noche)</span></p>")
    [void]$diasHtml.Append("<div class='comidas'><span>&#127869; <span class='ed' data-k='d$iDia-de'>$(HtmlEnc $dd.desayuno)</span></span><span>&#127860; <span class='ed' data-k='d$iDia-co'>$(HtmlEnc $dd.comida)</span></span><span>&#127869; <span class='ed' data-k='d$iDia-ce'>$(HtmlEnc $dd.cena)</span></span></div>")
    [void]$diasHtml.Append("</div></div>")
  }

  # datos para JS
  $viajerosJs  = ($Data.viajeros  | ConvertTo-Json -Compress)
  $checklistJs = ($Data.checklist | ConvertTo-Json -Compress)
  if ($checklistJs -notmatch '^\[') { $checklistJs = "[$checklistJs]" }
  $reservasJs  = ($Data.reservas  | ConvertTo-Json -Compress)
  if ($reservasJs -notmatch '^\[') { $reservasJs = "[$reservasJs]" }
  # compra: aplanar a [{item,grupo}] respetando el orden de los grupos
  $compraArr = @()
  foreach ($g in $Data.compra.PSObject.Properties) {
    foreach ($it in $g.Value) { $compraArr += [pscustomobject]@{ item = [string]$it; grupo = [string]$g.Name } }
  }
  $compraJs = ($compraArr | ConvertTo-Json -Compress)
  if ($compraJs -notmatch '^\[') { $compraJs = "[$compraJs]" }
  $pagador = [string]$Data.gasolinaPagador
  $comidaEst = [double]$Data.comidaEstimado

  $fechaPrecios = if ($Route.Fecha) { HtmlEnc $Route.Fecha } else { 'n/d' }
  $genTime = (Get-Date).ToString('dd/MM/yyyy HH:mm')
  $apiBadge = if ($ApiOk) { "<span class='pill ok'>&#9679; precios de hoy ($fechaPrecios)</span>" } else { "<span class='pill warn'>&#9679; sin conexion (precio aprox.)</span>" }

  $html = @"
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#2563eb">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="Viaje Amieva">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<title>$(HtmlEnc $Data.titulo)</title>
<style>
  :root{--bg:#eef2f9;--card:#fff;--ink:#15233d;--mut:#64748b;--line:#e7ecf5;--ac:#2563eb;--acs:#dbe6ff;--gd:#16a34a;--gds:#dcfce7;--bad:#e11d48;--bads:#ffe4ea;--wn:#b45309}
  *{box-sizing:border-box}
  html,body{margin:0}
  body{background:var(--bg);color:var(--ink);font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;font-size:16px;line-height:1.5;-webkit-text-size-adjust:100%}
  .wrap{max-width:760px;margin:0 auto;padding:16px 16px 92px}
  header{text-align:center;padding:8px 0 4px}
  header h1{margin:0;font-size:23px}
  header .sub{color:var(--mut);font-size:14px;margin-top:2px}
  .pill{display:inline-block;font-size:12px;padding:4px 10px;border-radius:20px;margin-top:8px;font-weight:600}
  .pill.ok{background:var(--gds);color:var(--gd)} .pill.warn{background:#fff3d6;color:var(--wn)}
  nav.tabs{position:fixed;left:0;right:0;bottom:0;z-index:20;background:#fff;border-top:1px solid var(--line);display:flex;box-shadow:0 -4px 16px rgba(20,35,61,.07)}
  nav.tabs button{flex:1;border:none;background:none;padding:8px 2px 10px;font-size:11px;color:var(--mut);display:flex;flex-direction:column;align-items:center;gap:3px;cursor:pointer;font-weight:600}
  nav.tabs button .ic{font-size:20px;line-height:1}
  nav.tabs button.active{color:var(--ac)}
  section.tab{display:none;animation:fade .2s}
  section.tab.active{display:block}
  @keyframes fade{from{opacity:0;transform:translateY(4px)}to{opacity:1;transform:none}}
  h2{font-size:14px;margin:18px 2px 10px;color:var(--mut);text-transform:uppercase;letter-spacing:.04em}
  .card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:16px;margin-bottom:14px;box-shadow:0 2px 8px rgba(20,35,61,.04)}
  .hero{text-align:center;background:linear-gradient(135deg,#2563eb,#4f86ff);color:#fff;border:none}
  .hero .cd{font-size:30px;font-weight:800} .hero .big{opacity:.92;font-size:14px;margin-top:2px}
  .kpis{display:grid;grid-template-columns:1fr 1fr;gap:10px}
  .kpi{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px;text-align:center;box-shadow:0 2px 8px rgba(20,35,61,.04)}
  .kpi .v{font-size:21px;font-weight:800;color:var(--ac)} .kpi .l{font-size:12px;color:var(--mut);margin-top:2px}
  .lead{background:var(--gds);border:1px solid #bbf7d0;border-radius:14px;padding:12px 14px;font-size:14px}
  .lead .t{font-size:12px;color:var(--gd);font-weight:700;text-transform:uppercase}
  table{width:100%;border-collapse:collapse;font-size:14px}
  th,td{padding:8px 6px;text-align:left;border-top:1px solid var(--line);vertical-align:top}
  th{color:var(--mut);font-weight:600;font-size:12px;border-top:none}
  .num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
  .dir{color:var(--mut);font-size:12px}
  .muted,.mut{color:var(--mut)} .gd{color:var(--gd);font-weight:600} .bad{color:var(--bad);font-weight:600}
  .zona{border:1px solid var(--line);border-radius:14px;padding:12px 14px;margin-bottom:10px}
  .zona-n{font-weight:700;font-size:15px;margin-bottom:6px}
  .zona-top{display:flex;justify-content:space-between;align-items:flex-start;gap:10px}
  .zona-sub{font-size:14px} .zona-meta{color:var(--mut);font-size:13px;margin-top:2px}
  .precio{font-size:22px;font-weight:800;color:var(--gd);white-space:nowrap}
  .precio span{font-size:12px;font-weight:600;color:var(--mut);margin-left:2px}
  .maplink{display:inline-block;margin-top:4px;color:var(--ac);font-weight:600;font-size:13px;text-decoration:none}
  .vermas{margin-top:8px;background:none;border:none;color:var(--ac);font-weight:600;font-size:13px;cursor:pointer;padding:0}
  .mas{display:none;margin-top:6px} .zona.show .mas{display:block}
  .dia{border:1px solid var(--line);border-radius:14px;margin-bottom:10px;overflow:hidden}
  .dia-h{width:100%;background:#fff;border:none;padding:14px;display:flex;justify-content:space-between;align-items:center;gap:10px;cursor:pointer;text-align:left}
  .dia-f{font-weight:700;font-size:15px} .dia-t{color:var(--mut);font-size:13px;margin-top:2px}
  .chev{font-size:22px;color:var(--mut);transition:transform .2s} .dia.open .chev{transform:rotate(90deg)}
  .dia-b{display:none;padding:0 14px 14px} .dia.open .dia-b{display:block}
  .dia-b p{margin:8px 0;font-size:14px}
  .lab{display:inline-block;background:var(--acs);color:var(--ac);font-size:11px;font-weight:700;text-transform:uppercase;padding:2px 7px;border-radius:6px;margin-right:6px}
  .comidas{margin-top:10px;border-top:1px dashed var(--line);padding-top:10px;display:flex;flex-direction:column;gap:4px;font-size:13px;color:var(--mut)}
  .hero2{text-align:center;background:linear-gradient(135deg,#16a34a,#22c55e);color:#fff;border:none}
  .hero2 .v{font-size:32px;font-weight:800} .hero2 .l{opacity:.92;font-size:13px}
  .addrow{display:flex;flex-wrap:wrap;gap:8px;margin:10px 0}
  input,select{font-size:15px;border:1px solid var(--line);border-radius:10px;padding:10px;background:#fff;color:var(--ink);font-family:inherit}
  input:focus,select:focus{outline:2px solid var(--acs);border-color:var(--ac)}
  .addrow input.con{flex:1;min-width:130px} .addrow input.imp{width:84px;text-align:right}
  button.add{background:var(--ac);color:#fff;border:none;border-radius:10px;padding:10px 16px;font-weight:700;font-size:18px;line-height:1;cursor:pointer}
  .line{display:flex;align-items:center;gap:8px;padding:10px 0;border-top:1px solid var(--line)}
  .line .gc{flex:1;font-size:14px} .line .gv{font-weight:700;white-space:nowrap}
  .line select.own{padding:6px 8px;font-size:13px}
  .line .gx{background:none;border:none;color:var(--bad);font-size:20px;cursor:pointer;padding:2px 6px}
  .hint{font-size:13px;color:var(--mut);margin:0 0 8px}
  .fold>summary{cursor:pointer;font-weight:700;font-size:14px;color:var(--ac);list-style:none}
  .fold>summary::-webkit-details-marker{display:none}
  .fold[open]>summary{margin-bottom:8px}
  .tag{font-size:11px;font-weight:700;padding:2px 8px;border-radius:20px;background:var(--acs);color:var(--ac);white-space:nowrap}
  .tag.comun{background:var(--line);color:var(--mut)}
  .prog{height:10px;background:var(--line);border-radius:6px;overflow:hidden;margin:6px 0 12px}
  .prog div{height:100%;background:var(--gd);width:0;transition:width .25s}
  .done{opacity:.45;text-decoration:line-through}
  .chk-item{display:flex;align-items:center;gap:10px;padding:11px 2px;border-top:1px solid var(--line)}
  .chk-item:first-child{border-top:none}
  .chk-item input[type=checkbox]{width:22px;height:22px;flex:none}
  .chk-item .txt{flex:1;font-size:15px}
  .chips{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:8px}
  .chips button{border:1px solid var(--line);background:#fff;color:var(--mut);border-radius:20px;padding:5px 12px;font-size:13px;cursor:pointer;font-weight:600}
  .chips button.on{background:var(--ac);color:#fff;border-color:var(--ac)}
  .wgrid{display:grid;grid-template-columns:repeat(4,1fr);gap:8px}
  .wday{background:#f8fafc;border:1px solid var(--line);border-radius:12px;padding:8px 4px;text-align:center}
  .wday.off{opacity:.6} .wd-f{font-size:12px;font-weight:700} .wd-i{font-size:22px;margin:2px 0} .wd-t{font-size:12px;font-weight:600} .wd-r{font-size:10px;color:var(--mut)}
  .sitio{display:flex;justify-content:space-between;align-items:center;padding:11px 2px;border-top:1px solid var(--line);color:var(--ink);text-decoration:none;font-size:14px;font-weight:600}
  .sitio:first-child{border-top:none} .sitio span{color:var(--mut);font-size:18px}
  textarea{width:100%;border:1px solid var(--line);border-radius:12px;padding:12px;font-family:inherit;font-size:15px;min-height:110px;resize:vertical;color:var(--ink)}
  textarea:focus{outline:2px solid var(--acs);border-color:var(--ac)}
  .grupo{font-size:12px;font-weight:700;color:var(--ac);text-transform:uppercase;letter-spacing:.03em;margin:14px 0 2px}
  .grupo:first-of-type{margin-top:4px}
  body.editing .ed{outline:1px dashed var(--ac);background:#f3f8ff;border-radius:4px}
  body.editing .ed:focus{outline:2px solid var(--ac);background:#fff}
  footer{text-align:center;color:var(--mut);font-size:12px;margin-top:18px}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>$(HtmlEnc $Data.titulo)</h1>
    <div class="sub">$(HtmlEnc $Data.fechas)</div>
    <div>$apiBadge</div>
  </header>

  <!-- INICIO -->
  <section id="t-inicio" class="tab active">
    <div class="card hero">
      <div class="cd">$diasTxt</div>
      <div class="big">$(HtmlEnc $Data.coche.modelo) &middot; Gasolina 95</div>
    </div>
    <div class="kpis">
      <div class="kpi"><div class="v">$autonomia km</div><div class="l">autonomia deposito lleno</div></div>
      <div class="kpi"><div class="v">$($costeIdaVuelta.ToString('0',$INV)) &euro;</div><div class="l">gasolina ida y vuelta aprox</div></div>
      <div class="kpi"><div class="v">8</div><div class="l">dias de viaje</div></div>
      <div class="kpi"><div class="v">$($refPrice.ToString('0.000',$INV))</div><div class="l">&euro;/L mas barato ruta</div></div>
    </div>
    <h2>Mejor sitio para repostar ahora</h2>
    <div class="card"><div class="lead"><div class="t">mas barata de la ruta</div>$cheapTxt</div></div>

    <h2>El tiempo en Amieva</h2>
    <div class="card">
      <div class="wgrid">$($weatherHtml.ToString())</div>
      $(if (-not $hayTiempo) { "<p class='hint' style='margin:10px 0 0'>La prevision aparece cuando faltan ~15 dias. Vuelve a abrir el panel mas cerca de la fecha.</p>" } else { "<p class='hint' style='margin:10px 0 0'>Maximas/minimas y probabilidad de lluvia. Se actualiza cada vez que abres el panel.</p>" })
    </div>

    <h2>Antes de salir</h2>
    <div class="card"><div id="res-list"></div></div>

    <h2>Notas</h2>
    <div class="card"><textarea id="notas" placeholder="Apunta aqui cualquier cosa: ideas, lo que falta, lo que diga Jorge..."></textarea></div>

    <h2>La casa</h2>
    <div class="card">
      <div class="mut" style="font-size:14px">$(HtmlEnc $Data.casa)</div>
    </div>

    <details class="card fold">
      <summary>Como usarla en el movil</summary>
      <p class="hint" style="margin-top:8px">1. Abre este archivo (index.html) en el movil (te lo envias por WhatsApp/Telegram o lo abres desde Drive).<br>2. En el menu de Chrome (3 puntos) pulsa <b>Anadir a pantalla de inicio</b>: queda como una app.<br>3. Pasaselo igual a tu copiloto para que siga el plan.<br>Los precios y el tiempo se actualizan solos cada dia en la web, no tienes que hacer nada.</p>
    </details>
  </section>

  <!-- GASOLINA -->
  <section id="t-gas" class="tab">
    <h2>Donde repostar (95)</h2>
    <p class="hint" style="margin:0 2px 10px">En cada parada te marco la mejor opcion teniendo en cuenta el desvio: si una mas barata esta lejos y no compensa el gasto de ir, no la recomiendo. Calculo pensando en repostar unos $($litros.ToString('0',$INV)) L.</p>
    <div class="card" style="padding:14px">
      $($gasHtml.ToString())
    </div>
    <h2>Coste y autonomia</h2>
    <div class="card"><div class="lead" style="background:#fff7ed;border-color:#fed7aa"><div class="t" style="color:var(--wn)">peajes y ruta</div>$(HtmlEnc $Data.rutaNota)</div></div>
    <div class="card">
      <table><tr><th>Tramo (ida)</th><th class="num">km</th><th class="num">litros</th><th class="num">coste</th></tr>
        $($tramosHtml.ToString())
        <tr style="font-weight:700"><td>Total ida</td><td class="num">$($kmIda.ToString('0',$INV))</td><td class="num">$($litrosIda.ToString('0.0',$INV))</td><td class="num">$($costeIda.ToString('0.00',$INV)) &euro;</td></tr>
      </table>
      <p class="hint" style="margin-top:12px">Con el deposito lleno aguantas ~$autonomia km, asi que el tramo final a Amieva lo haces de sobra aunque no haya gasolineras cerca. Reposta despues de Burgos o en Riano antes de subir.</p>
    </div>
  </section>

  <!-- DINERO -->
  <section id="t-dinero" class="tab">
    <h2>Gasolina (la pones tu)</h2>
    <div class="card hero2"><div class="v">Cada uno te da <span id="gas-cuota">0</span> &euro;</div><div class="l">al final del viaje &middot; total gasolina <span id="gas-total">0</span> &euro;</div></div>
    <div class="card">
      <p class="hint">Apunta cada vez que repostes. Pagas tu y al final lo divides entre los 4: los otros tres te devuelven su parte.</p>
      <div class="addrow">
        <input class="con" id="gas-con" placeholder="Donde (ej. Logrono)">
        <input class="imp" id="gas-imp" type="number" inputmode="decimal" step="0.01" placeholder="&euro;">
        <button class="add" onclick="addGas()">+</button>
      </div>
      <div id="gas-list"></div>
    </div>

    <h2>Comida</h2>
    <div class="card">
      <p class="hint">Cada uno paga la suya. Esto es solo una estimacion para que sepas mas o menos cuanto llevar.</p>
      <div class="addrow" style="align-items:center">
        <span style="font-size:14px">Estimado total del viaje:</span>
        <input class="imp" id="com-tot" type="number" inputmode="decimal" step="10" value="$($comidaEst.ToString('0',$INV))" oninput="renderComida()"> <span style="font-size:14px">&euro;</span>
      </div>
      <div style="font-size:15px">Sale a <b><span id="com-pp">0</span> &euro;</b> por persona aprox.</div>
    </div>

    <details class="card fold">
      <summary>Otros gastos compartidos (excepciones)</summary>
      <p class="hint">Solo para cosas que pague uno por todos (una comida conjunta, un peaje...). Se reparte entre 4 y te digo quien paga a quien.</p>
      <div class="addrow">
        <input class="con" id="sh-con" placeholder="Concepto">
        <input class="imp" id="sh-imp" type="number" inputmode="decimal" step="0.01" placeholder="&euro;">
        <select id="sh-pag"></select>
        <button class="add" onclick="addShared()">+</button>
      </div>
      <div id="sh-list"></div>
      <div id="sh-liq" class="hint" style="margin-top:10px"></div>
    </details>
  </section>

  <!-- PLAN -->
  <section id="t-plan" class="tab">
    <h2>Sitios (abrir en Maps)</h2>
    <div class="card">$($sitiosHtml.ToString())</div>
    <h2>Plan dia a dia</h2>
    <div class="card" style="display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap">
      <span class="hint" style="margin:0">Toca <b>Editar</b> para cambiar los textos del plan. Se guardan en este movil.</span>
      <span style="display:flex;gap:8px"><button id="resetEdit" class="reset" style="display:none;margin:0" onclick="resetEdits()">Restaurar</button><button id="editBtn" class="add" style="padding:8px 14px" onclick="toggleEdit()">&#9999;&#65039; Editar</button></span>
    </div>
    $($diasHtml.ToString())
  </section>

  <!-- LISTAS (maleta + compra) -->
  <section id="t-listas" class="tab">
    <div class="chips" id="l-tabs">
      <button class="on" onclick="showLista('maleta',this)">Maleta</button>
      <button onclick="showLista('compra',this)">Compra</button>
    </div>

    <div id="l-maleta">
      <div class="card">
        <p class="hint">Anade cosas y di quien las lleva. Marca el cuadrito cuando ya este metido.</p>
        <div class="addrow">
          <input class="con" id="m-item" placeholder="Que llevar (ej. Sombrilla)">
          <select id="m-quien"></select>
          <button class="add" onclick="addItem()">+</button>
        </div>
        <div class="chips" id="m-filtros"></div>
        <div class="mut" style="font-size:13px"><span id="m-n">0</span> de <span id="m-tot">0</span> preparado</div>
        <div class="prog"><div id="m-bar"></div></div>
        <div id="m-list"></div>
      </div>
    </div>

    <div id="l-compra" style="display:none">
      <div class="card">
        <p class="hint">La compra del viaje (Logrono y Mercadona Arriondas). Marca lo que vayas metiendo en el carro. Puedes anadir mas.</p>
        <div class="addrow">
          <input class="con" id="c-item" placeholder="Anadir producto">
          <select id="c-grupo"></select>
          <button class="add" onclick="addCompra()">+</button>
        </div>
        <div class="mut" style="font-size:13px"><span id="c-n">0</span> de <span id="c-tot">0</span> comprado</div>
        <div class="prog"><div id="c-bar"></div></div>
        <div id="c-list"></div>
      </div>
    </div>
  </section>

  <footer>Los precios de gasolina y el tiempo se actualizan solos cada dia. Lo que apuntes (gastos, maleta, notas, ediciones del plan) se guarda en este movil.</footer>
</div>

<nav class="tabs">
  <button class="active" onclick="showTab('t-inicio',this)"><span class="ic">&#127968;</span>Inicio</button>
  <button onclick="showTab('t-gas',this)"><span class="ic">&#9981;</span>Gasolina</button>
  <button onclick="showTab('t-dinero',this)"><span class="ic">&#128176;</span>Dinero</button>
  <button onclick="showTab('t-plan',this)"><span class="ic">&#128506;</span>Plan</button>
  <button onclick="showTab('t-listas',this)"><span class="ic">&#128203;</span>Listas</button>
</nav>
"@

  $script = @'
<script>
const VIAJEROS = __VIAJEROS__;
const SEED_CHECK = __CHECK__;
const SEED_RESERVAS = __RESERVAS__;
const SEED_COMPRA = __COMPRA__;
const PAGADOR = __PAGADOR__;
const eur = n => (Math.round(n*100)/100).toLocaleString('es-ES',{minimumFractionDigits:2,maximumFractionDigits:2});
const K_GAS='viajeAmieva_gas2', K_SH='viajeAmieva_shared', K_MAL='viajeAmieva_maleta2';
const K_RES='viajeAmieva_reservas', K_NOT='viajeAmieva_notas', K_COM='viajeAmieva_compra';
const load=(k,def)=>{ try{ const v=JSON.parse(localStorage.getItem(k)); return v??def; }catch(e){ return def; } };

function showTab(id, btn){
  document.querySelectorAll('section.tab').forEach(s=>s.classList.toggle('active', s.id===id));
  document.querySelectorAll('nav.tabs button').forEach(b=>b.classList.remove('active'));
  btn.classList.add('active'); window.scrollTo(0,0);
}
function toggleDia(b){ b.parentElement.classList.toggle('open'); }
function toggleNext(b){ b.parentElement.classList.toggle('show'); }
function showLista(id, btn){
  document.getElementById('l-maleta').style.display = id==='maleta'?'':'none';
  document.getElementById('l-compra').style.display = id==='compra'?'':'none';
  document.querySelectorAll('#l-tabs button').forEach(b=>b.classList.remove('on'));
  btn.classList.add('on');
}

/* ---- Gasolina (la pone PAGADOR, se divide entre todos) ---- */
let repos = load(K_GAS, []);
function saveGas(){ localStorage.setItem(K_GAS, JSON.stringify(repos)); }
function addGas(){
  const con=document.getElementById('gas-con').value.trim()||'Repostaje';
  const imp=parseFloat(document.getElementById('gas-imp').value);
  if(isNaN(imp)){ alert('Pon los euros del repostaje.'); return; }
  repos.push({nota:con, importe:imp}); saveGas();
  document.getElementById('gas-con').value=''; document.getElementById('gas-imp').value='';
  renderGas();
}
function delGas(i){ repos.splice(i,1); saveGas(); renderGas(); }
function renderGas(){
  const list=document.getElementById('gas-list'); list.innerHTML=''; let total=0;
  repos.forEach((r,i)=>{ total+=Number(r.importe)||0;
    const row=document.createElement('div'); row.className='line';
    row.innerHTML='<span class="gc">'+r.nota+'</span><span class="gv">'+eur(r.importe)+' &euro;</span>'+
      '<button class="gx" onclick="delGas('+i+')">&times;</button>';
    list.appendChild(row);
  });
  document.getElementById('gas-total').textContent=eur(total);
  document.getElementById('gas-cuota').textContent=eur(total/VIAJEROS.length);
}

/* ---- Comida (cada uno la suya, solo estimacion) ---- */
function renderComida(){
  const t=parseFloat(document.getElementById('com-tot').value)||0;
  document.getElementById('com-pp').textContent=eur(t/VIAJEROS.length);
}

/* ---- Gastos compartidos (excepciones) ---- */
let shared = load(K_SH, []);
function saveSh(){ localStorage.setItem(K_SH, JSON.stringify(shared)); }
document.getElementById('sh-pag').innerHTML='<option value="">quien pago</option>'+VIAJEROS.map(v=>'<option>'+v+'</option>').join('');
function addShared(){
  const con=document.getElementById('sh-con').value.trim();
  const imp=parseFloat(document.getElementById('sh-imp').value);
  const pag=document.getElementById('sh-pag').value;
  if(!con||isNaN(imp)){ alert('Pon concepto e importe.'); return; }
  shared.push({concepto:con, importe:imp, pagadoPor:pag}); saveSh();
  document.getElementById('sh-con').value=''; document.getElementById('sh-imp').value=''; document.getElementById('sh-pag').value='';
  renderSh();
}
function delSh(i){ shared.splice(i,1); saveSh(); renderSh(); }
function setShPag(i,v){ shared[i].pagadoPor=v; saveSh(); renderSh(); }
function renderSh(){
  const list=document.getElementById('sh-list'); list.innerHTML='';
  const pagado={}; VIAJEROS.forEach(v=>pagado[v]=0); let total=0;
  shared.forEach((g,i)=>{ total+=Number(g.importe)||0; if(g.pagadoPor&&pagado.hasOwnProperty(g.pagadoPor)) pagado[g.pagadoPor]+=Number(g.importe)||0;
    const opts='<option value="">nadie</option>'+VIAJEROS.map(v=>'<option '+(v===g.pagadoPor?'selected':'')+'>'+v+'</option>').join('');
    const row=document.createElement('div'); row.className='line';
    row.innerHTML='<span class="gc">'+g.concepto+'</span><span class="gv">'+eur(g.importe)+' &euro;</span>'+
      '<select class="own" onchange="setShPag('+i+',this.value)">'+opts+'</select>'+
      '<button class="gx" onclick="delSh('+i+')">&times;</button>';
    list.appendChild(row);
  });
  const cuota=total/VIAJEROS.length, saldos={};
  VIAJEROS.forEach(v=>saldos[v]=pagado[v]-cuota);
  document.getElementById('sh-liq').innerHTML = total>0 ? liquidar(saldos) : '';
}
function liquidar(saldos){
  const deb=[],acr=[];
  Object.keys(saldos).forEach(v=>{ const s=Math.round(saldos[v]*100)/100; if(s<-0.01)deb.push([v,-s]); else if(s>0.01)acr.push([v,s]); });
  if(!deb.length) return 'Compartidos: todo cuadrado.';
  deb.sort((a,b)=>b[1]-a[1]); acr.sort((a,b)=>b[1]-a[1]);
  const pasos=[]; let i=0,j=0;
  while(i<deb.length&&j<acr.length){ const m=Math.min(deb[i][1],acr[j][1]);
    pasos.push('<b>'+deb[i][0]+'</b> da <b>'+eur(m)+' &euro;</b> a <b>'+acr[j][0]+'</b>');
    deb[i][1]-=m; acr[j][1]-=m; if(deb[i][1]<0.01)i++; if(acr[j][1]<0.01)j++; }
  return 'Para cuadrar:<br>'+pasos.join('<br>');
}

/* ---- Maleta editable ---- */
const OWNERS = VIAJEROS.concat(['Comun']);
let maleta = load(K_MAL, null);
if(!Array.isArray(maleta)){ maleta = SEED_CHECK.map(x=>({item:x, quien:'Comun', ok:false})); localStorage.setItem(K_MAL, JSON.stringify(maleta)); }
let filtro='Todos';
function saveMal(){ localStorage.setItem(K_MAL, JSON.stringify(maleta)); }
document.getElementById('m-quien').innerHTML=OWNERS.map(v=>'<option'+(v==='Comun'?' selected':'')+'>'+v+'</option>').join('');
function addItem(){
  const it=document.getElementById('m-item').value.trim();
  const q=document.getElementById('m-quien').value;
  if(!it){ alert('Escribe que llevar.'); return; }
  maleta.push({item:it, quien:q, ok:false}); saveMal();
  document.getElementById('m-item').value='';
  renderMaleta();
}
function delItem(i){ maleta.splice(i,1); saveMal(); renderMaleta(); }
function toggleItem(i){ maleta[i].ok=!maleta[i].ok; saveMal(); renderMaleta(); }
function setFiltro(f){ filtro=f; renderMaleta(); }
function renderMaleta(){
  const fil=document.getElementById('m-filtros'); fil.innerHTML='';
  ['Todos'].concat(OWNERS).forEach(f=>{
    const b=document.createElement('button'); b.textContent=f; if(f===filtro)b.className='on';
    b.onclick=()=>setFiltro(f); fil.appendChild(b);
  });
  const list=document.getElementById('m-list'); list.innerHTML='';
  let shown=0, done=0;
  maleta.forEach((m,i)=>{
    if(filtro!=='Todos' && m.quien!==filtro) return;
    shown++; if(m.ok)done++;
    const tagcls = m.quien==='Comun' ? 'tag comun':'tag';
    const row=document.createElement('div'); row.className='chk-item';
    row.innerHTML='<input type="checkbox" '+(m.ok?'checked':'')+' onchange="toggleItem('+i+')">'+
      '<span class="txt '+(m.ok?'done':'')+'">'+m.item+'</span>'+
      '<span class="'+tagcls+'">'+m.quien+'</span>'+
      '<button class="gx" onclick="delItem('+i+')">&times;</button>';
    list.appendChild(row);
  });
  document.getElementById('m-tot').textContent=shown;
  document.getElementById('m-n').textContent=done;
  document.getElementById('m-bar').style.width=(shown?Math.round(done/shown*100):0)+'%';
}

/* ---- Compra (lista del viaje, agrupada y marcable) ---- */
let compra = load(K_COM, null);
if(!Array.isArray(compra)){ compra = SEED_COMPRA.map(x=>({item:x.item, grupo:x.grupo, ok:false})); localStorage.setItem(K_COM, JSON.stringify(compra)); }
function saveCom(){ localStorage.setItem(K_COM, JSON.stringify(compra)); }
const GRUPOS = SEED_COMPRA.reduce((a,x)=>{ if(!a.includes(x.grupo))a.push(x.grupo); return a; }, []);
document.getElementById('c-grupo').innerHTML=GRUPOS.map(g=>'<option>'+g+'</option>').join('');
function addCompra(){
  const it=document.getElementById('c-item').value.trim();
  const g=document.getElementById('c-grupo').value || (GRUPOS[0]||'Compra');
  if(!it){ alert('Escribe el producto.'); return; }
  compra.push({item:it, grupo:g, ok:false}); saveCom();
  document.getElementById('c-item').value=''; renderCompra();
}
function delCompra(i){ compra.splice(i,1); saveCom(); renderCompra(); }
function toggleCompra(i){ compra[i].ok=!compra[i].ok; saveCom(); renderCompra(); }
function renderCompra(){
  const list=document.getElementById('c-list'); list.innerHTML='';
  let done=0;
  const grupos=[]; compra.forEach(c=>{ if(!grupos.includes(c.grupo))grupos.push(c.grupo); });
  grupos.forEach(g=>{
    const h=document.createElement('div'); h.className='grupo'; h.textContent=g; list.appendChild(h);
    compra.forEach((c,i)=>{
      if(c.grupo!==g) return; if(c.ok)done++;
      const row=document.createElement('div'); row.className='chk-item';
      row.innerHTML='<input type="checkbox" '+(c.ok?'checked':'')+' onchange="toggleCompra('+i+')">'+
        '<span class="txt '+(c.ok?'done':'')+'">'+c.item+'</span>'+
        '<button class="gx" onclick="delCompra('+i+')">&times;</button>';
      list.appendChild(row);
    });
  });
  document.getElementById('c-tot').textContent=compra.length;
  document.getElementById('c-n').textContent=done;
  document.getElementById('c-bar').style.width=(compra.length?Math.round(done/compra.length*100):0)+'%';
}

/* ---- Antes de salir (reservas) ---- */
let reservas = load(K_RES, null);
if(!Array.isArray(reservas)){ reservas = SEED_RESERVAS.map(x=>({item:x, ok:false})); localStorage.setItem(K_RES, JSON.stringify(reservas)); }
function saveRes(){ localStorage.setItem(K_RES, JSON.stringify(reservas)); }
function toggleRes(i){ reservas[i].ok=!reservas[i].ok; saveRes(); renderRes(); }
function renderRes(){
  const list=document.getElementById('res-list'); list.innerHTML='';
  reservas.forEach((r,i)=>{
    const row=document.createElement('div'); row.className='chk-item';
    row.innerHTML='<input type="checkbox" '+(r.ok?'checked':'')+' onchange="toggleRes('+i+')">'+
      '<span class="txt '+(r.ok?'done':'')+'">'+r.item+'</span>';
    list.appendChild(row);
  });
}

/* ---- Notas ---- */
const ta=document.getElementById('notas');
ta.value = load(K_NOT, '') || '';
ta.addEventListener('input', ()=>localStorage.setItem(K_NOT, JSON.stringify(ta.value)));

/* ---- Editar textos del plan (se guardan en este dispositivo) ---- */
let editing=false;
function applyEdits(){ document.querySelectorAll('.ed').forEach(e=>{ const v=localStorage.getItem('ed_'+e.dataset.k); if(v!==null) e.innerText=v; }); }
function toggleEdit(){
  editing=!editing;
  document.querySelectorAll('.ed').forEach(e=>{ e.contentEditable = editing?'true':'false'; });
  document.body.classList.toggle('editing', editing);
  document.getElementById('editBtn').innerHTML = editing ? '&#10003; Hecho' : '&#9999;&#65039; Editar';
  document.getElementById('resetEdit').style.display = editing ? '' : 'none';
}
document.addEventListener('input', e=>{ const t=e.target; if(t.classList && t.classList.contains('ed')){ localStorage.setItem('ed_'+t.dataset.k, t.innerText); } });
function resetEdits(){ if(confirm('Borrar tus cambios y volver al plan original?')){ document.querySelectorAll('.ed').forEach(e=>localStorage.removeItem('ed_'+e.dataset.k)); location.reload(); } }

renderGas(); renderComida(); renderSh(); renderMaleta(); renderCompra(); renderRes(); applyEdits();
</script>
'@

  $script = $script.Replace('__VIAJEROS__', $viajerosJs).Replace('__CHECK__', $checklistJs).Replace('__RESERVAS__', $reservasJs).Replace('__COMPRA__', $compraJs).Replace('__PAGADOR__', ($pagador | ConvertTo-Json))
  $full = $html + "`r`n" + $script + "`r`n</body>`r`n</html>`r`n"
  $full | Set-Content -Path $HtmlPath -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if (-not (Test-Path $DataPath)) { throw "No existe datos.json junto al script." }
$Data = Get-Content $DataPath -Raw -Encoding UTF8 | ConvertFrom-Json

$apiOk = $false
$Weather = @{}
if ($NoApi) {
  Write-Host "Modo sin API: panel sin precios ni tiempo." -ForegroundColor Yellow
  $Route = [pscustomobject]@{ Fecha=''; Paradas=@() }
} else {
  try {
    $Route = Get-RouteStations -Data $Data
    $apiOk = $true
  } catch {
    Write-Host "No se pudo consultar la API ($($_.Exception.Message)). Genero el panel sin precios." -ForegroundColor Yellow
    $Route = [pscustomobject]@{ Fecha=''; Paradas=@() }
  }
  try { $Weather = Get-Weather -Data $Data } catch { $Weather = @{} }
}

Build-Html -Data $Data -Route $Route -ApiOk $apiOk -Weather $Weather
Write-Host "Panel generado: $HtmlPath" -ForegroundColor Green
if (-not $NoOpen) { Start-Process $HtmlPath }

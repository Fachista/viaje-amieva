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
    $pdia = if ($p.PSObject.Properties['dia']) { [int]$p.dia } else { -1 }
    $result += [pscustomobject]@{ Nombre = $p.nombre; Dia = $pdia; Estaciones = $stations }
  }
  return [pscustomobject]@{ Fecha = $fecha; Paradas = $result }
}

# Economia del desvio: devuelve la parada con estacion recomendada y lista evaluada
function Resolve-Economics {
  param($Parada, [double]$Consumo, [double]$Litros)
  $pdia = if ($Parada.PSObject.Properties['Dia']) { [int]$Parada.Dia } else { -1 }
  $est = @($Parada.Estaciones)
  if ($est.Count -eq 0) { return [pscustomobject]@{ Nombre=$Parada.Nombre; Dia=$pdia; Reco=$null; Lista=@(); RefPrecio=$null } }

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
  return [pscustomobject]@{ Nombre=$Parada.Nombre; Dia=$pdia; Reco=$reco; Lista=$lista; RefPrecio=$refPrecio }
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
  $dayWx = @{}     # idx -> @{ Icon; Texto; TMax; TMin; Rain }
  $dayFecha = @{}  # idx -> "Sab 11"
  try {
    $inicioW = [datetime]::ParseExact([string]$Data.fechaInicio,'yyyy-MM-dd',$INV)
    $dias3 = @('Dom','Lun','Mar','Mie','Jue','Vie','Sab')
    for ($i = 0; $i -lt $Data.dias.Count; $i++) {
      $fd = $inicioW.AddDays($i)
      $key = $fd.ToString('yyyy-MM-dd')
      $etq = $dias3[[int]$fd.DayOfWeek] + ' ' + $fd.Day
      $dayFecha[$i] = $etq
      if ($Weather.ContainsKey($key)) {
        $hayTiempo = $true
        $wi = $Weather[$key]
        $ico = (Get-WeatherIcon $wi.Code)
        $dayWx[$i] = [pscustomobject]@{ Icon=$ico[0]; Texto=$ico[1]; TMax=$wi.TMax; TMin=$wi.TMin; Rain=$wi.Rain }
        [void]$weatherHtml.Append("<div class='wday'><div class='wd-f'>$etq</div><div class='wd-i'>$($ico[0])</div><div class='wd-t'>$($wi.TMax)&deg; / $($wi.TMin)&deg;</div><div class='wd-r'>&#127783;&#65039; $($wi.Rain)%</div></div>")
      } else {
        [void]$weatherHtml.Append("<div class='wday off'><div class='wd-f'>$etq</div><div class='wd-i'>&middot;&middot;&middot;</div><div class='wd-t muted' style='font-size:11px'>lejos</div></div>")
      }
    }
  } catch { }

  # que dia del viaje es "hoy" (-1 antes, 0..n durante, 99 despues)
  $todayIdx = -1
  try {
    $st = [datetime]::ParseExact([string]$Data.fechaInicio,'yyyy-MM-dd',$INV).Date
    $df = [int][math]::Floor(((Get-Date).Date - $st).TotalDays)
    if ($df -ge 0 -and $df -lt $Data.dias.Count) { $todayIdx = $df }
    elseif ($df -ge $Data.dias.Count) { $todayIdx = 99 }
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

  # ---- Itinerario unificado: cada dia reune plan + gasolinera + tiempo + comidas + sitios ----
  $itinHtml = New-Object Text.StringBuilder
  [void]$itinHtml.Append("<div class='trip'>")
  for ($i = 0; $i -lt $Data.dias.Count; $i++) {
    $dd = $Data.dias[$i]
    $iDia = $i + 1
    $parts = [string]$dd.fecha -split ' - ', 2
    $dpart = $parts[0].Trim()
    $tpart = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
    $teaser = ([string]$dd.manana -split '\. ')[0]
    if ($teaser.Length -gt 78) { $teaser = $teaser.Substring(0,75) + '...' }
    $isHoy = ($i -eq $todayIdx)
    $open = if ($isHoy -or ($todayIdx -lt 0 -and $i -eq 0) -or ($todayIdx -eq 99 -and $i -eq ($Data.dias.Count - 1))) { ' open' } else { '' }
    $dotCls = if ($isHoy) { 'jdot hoy' } else { 'jdot' }
    $wx = if ($dayWx.ContainsKey($i)) { $dayWx[$i] } else { $null }
    $wxMini = if ($wx) { "<span class='jwx'>$($wx.Icon) $($wx.TMax)&deg;</span>" } else { '' }
    $hoyTag = if ($isHoy) { " <span class='hoytag'>HOY</span>" } else { '' }

    [void]$itinHtml.Append("<div class='jday'><div class='jnode'><span class='$dotCls'>$i</span></div>")
    [void]$itinHtml.Append("<div class='jcard$open' id='jday$i'>")
    [void]$itinHtml.Append("<button class='jhead' onclick='toggleDia(this)'><div class='jmeta'><div class='jdate'>$(HtmlEnc $dpart)$hoyTag</div><div class='jtitle'>$(HtmlEnc $tpart)</div><div class='jteaser'>$(HtmlEnc $teaser)</div></div><div class='jright'>$wxMini<span class='chev'>&rsaquo;</span></div></button>")
    [void]$itinHtml.Append("<div class='jbody'>")
    [void]$itinHtml.Append("<div class='seg'><span class='seg-t'>Manana</span><span class='ed' data-k='d$iDia-m'>$(HtmlEnc $dd.manana)</span></div>")
    [void]$itinHtml.Append("<div class='seg'><span class='seg-t'>Tarde</span><span class='ed' data-k='d$iDia-t'>$(HtmlEnc $dd.tarde)</span></div>")
    [void]$itinHtml.Append("<div class='seg'><span class='seg-t'>Noche</span><span class='ed' data-k='d$iDia-n'>$(HtmlEnc $dd.noche)</span></div>")
    $dayGas = @($ecos | Where-Object { $_.Dia -eq $i -and $_.Reco })
    foreach ($g in $dayGas) {
      $r = $g.Reco
      $mp = "https://www.google.com/maps/search/?api=1&query=$(([double]$r.Lat).ToString('0.######',$INV)),$(([double]$r.Lon).ToString('0.######',$INV))"
      $dv = if ($r.ExtraKm -le 0.6) { 'de paso' } else { "+$($r.ExtraKm.ToString('0.#',$INV)) km" }
      [void]$itinHtml.Append("<a class='dline gas' href='$mp' target='_blank'><span class='dline-ic'>&#9981;</span><span class='dline-tx'><b>$(HtmlEnc $r.Rotulo)</b><small>$(HtmlEnc $r.Municipio) &middot; $dv</small></span><span class='dline-v'>$(([double]$r.Precio).ToString('0.000',$INV))<small>&euro;/L</small></span></a>")
    }
    if ($wx) {
      [void]$itinHtml.Append("<div class='dline'><span class='dline-ic'>$($wx.Icon)</span><span class='dline-tx'><b>Tiempo</b><small>$(HtmlEnc $wx.Texto)</small></span><span class='dline-v'>$($wx.TMax)&deg;/$($wx.TMin)&deg;<small>&#127783;&#65039; $($wx.Rain)%</small></span></div>")
    }
    [void]$itinHtml.Append("<div class='meals'>")
    [void]$itinHtml.Append("<div class='meal'><span class='meal-l'>&#127869; Desayuno</span><span class='ed' data-k='d$iDia-de'>$(HtmlEnc $dd.desayuno)</span></div>")
    [void]$itinHtml.Append("<div class='meal'><span class='meal-l'>&#127860; Comida</span><span class='ed' data-k='d$iDia-co'>$(HtmlEnc $dd.comida)</span></div>")
    [void]$itinHtml.Append("<div class='meal'><span class='meal-l'>&#127869; Cena</span><span class='ed' data-k='d$iDia-ce'>$(HtmlEnc $dd.cena)</span></div>")
    [void]$itinHtml.Append("</div>")
    $daySit = @($Data.sitios | Where-Object { $_.PSObject.Properties['dia'] -and [int]$_.dia -eq $i })
    if ($daySit.Count -gt 0) {
      [void]$itinHtml.Append("<div class='dsites'><div class='dsites-t'>Sitios de este dia</div>")
      foreach ($s in $daySit) {
        $sm = "https://www.google.com/maps/search/?api=1&query=$(([double]$s.lat).ToString('0.######',$INV)),$(([double]$s.lon).ToString('0.######',$INV))"
        [void]$itinHtml.Append("<a class='dsite' href='$sm' target='_blank'>&#128205; $(HtmlEnc $s.nombre)<span>&rsaquo;</span></a>")
      }
      [void]$itinHtml.Append("</div>")
    }
    [void]$itinHtml.Append("</div></div></div>")
  }
  [void]$itinHtml.Append("</div>")

  # ---- Tarjeta "Hoy" / preparativos (cambia segun la fecha) ----
  $hoyHtml = New-Object Text.StringBuilder
  if ($todayIdx -ge 0 -and $todayIdx -lt $Data.dias.Count) {
    $tdd = $Data.dias[$todayIdx]
    $tp = [string]$tdd.fecha -split ' - ', 2
    $ttitle = if ($tp.Count -ge 2) { $tp[1].Trim() } else { $tp[0].Trim() }
    $tteaser = ([string]$tdd.manana -split '\. ')[0]
    [void]$hoyHtml.Append("<div class='card hoy spot'><div class='hoy-eyebrow'>&#9733; Lo de hoy &middot; dia $todayIdx de $($Data.dias.Count - 1)</div>")
    [void]$hoyHtml.Append("<div class='hoy-title'>$(HtmlEnc $ttitle)</div><div class='hoy-teaser'>$(HtmlEnc $tteaser)</div>")
    foreach ($g in @($ecos | Where-Object { $_.Dia -eq $todayIdx -and $_.Reco })) { $r=$g.Reco; [void]$hoyHtml.Append("<div class='hoy-line'>&#9981; $(HtmlEnc $r.Rotulo) &middot; $(([double]$r.Precio).ToString('0.000',$INV)) &euro;/L</div>") }
    if ($dayWx.ContainsKey($todayIdx)) { $w=$dayWx[$todayIdx]; [void]$hoyHtml.Append("<div class='hoy-line'>$($w.Icon) $($w.TMax)&deg;/$($w.TMin)&deg; &middot; $($w.Rain)% lluvia</div>") }
    [void]$hoyHtml.Append("<button class='hoy-btn' onclick='irAlDia($todayIdx)'>Ver el dia completo &rsaquo;</button></div>")
  }
  elseif ($todayIdx -eq 99) {
    [void]$hoyHtml.Append("<div class='card hoy spot'><div class='hoy-eyebrow'>Viaje terminado</div><div class='hoy-teaser'>Esperamos que fuera un viajazo. El plan sigue aqui por si quereis recordar algo.</div></div>")
  }
  else {
    [void]$hoyHtml.Append("<div class='card hoy'><div class='hoy-eyebrow'>Preparativos</div><div class='rings'>")
    foreach ($rg in @(@('res','Reservas'), @('mal','Maleta'), @('com','Compra'))) {
      [void]$hoyHtml.Append("<div class='ring'><svg viewBox='0 0 44 44'><circle class='ring-bg' cx='22' cy='22' r='18'/><circle class='ring-fg' id='ring-$($rg[0])' cx='22' cy='22' r='18'/></svg><div class='ring-c' id='rv-$($rg[0])'>0/0</div><div class='ring-l'>$($rg[1])</div></div>")
    }
    [void]$hoyHtml.Append("</div><div class='hint' style='margin:12px 0 0'>Reservas, maleta y compra: se actualizan solos y los veis los dos.</div></div>")
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
<meta name="theme-color" content="#3b5bff">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="Viaje Amieva">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<title>$(HtmlEnc $Data.titulo)</title>
<style>
  :root{
    --bg:#eaeefb;--bg2:#e3e9fb;--card:#ffffff;--card-2:#f5f7ff;
    --ink:#0f1b33;--ink-soft:#37415a;--mut:#6b7794;
    --line:rgba(15,27,51,.09);--line-2:rgba(15,27,51,.05);
    --ac:#3b5bff;--ac-ink:#2540d8;--acs:#e7ecff;--vio:#7c5cff;--cyan:#19b6e6;
    --gd:#0fae6e;--gd-ink:#0a8f5c;--gds:#dcfff0;--bad:#f43f6e;--bads:#ffe3ec;--wn:#b8730a;--wns:#fff1d6;
    --grad:linear-gradient(135deg,#3b5bff 0%,#7c5cff 55%,#19b6e6 120%);
    --grad-gd:linear-gradient(135deg,#0fae6e,#34d39a);
    --shadow:0 14px 34px -16px rgba(20,30,70,.32);--shadow-s:0 4px 16px -8px rgba(20,30,70,.22);
    --r:20px;--r-s:14px;color-scheme:light dark;
  }
  @media (prefers-color-scheme:dark){:root{
    --bg:#0a1020;--bg2:#0c1430;--card:#141d33;--card-2:#1a2545;
    --ink:#eef2fb;--ink-soft:#c6cee2;--mut:#8a96b4;
    --line:rgba(255,255,255,.10);--line-2:rgba(255,255,255,.05);
    --acs:#1d2b55;--gds:#0e2e22;--bads:#3a1626;--wns:#352a10;--gd-ink:#33d39a;--ac-ink:#9db4ff;
    --shadow:0 16px 40px -18px rgba(0,0,0,.7);--shadow-s:0 6px 20px -10px rgba(0,0,0,.55);
  }}
  *{box-sizing:border-box}
  html,body{margin:0}
  body{background:radial-gradient(1100px 600px at 100% -8%,rgba(124,92,255,.18),transparent 60%),radial-gradient(900px 520px at -8% 4%,rgba(25,182,230,.16),transparent 55%),linear-gradient(180deg,var(--bg),var(--bg2));background-attachment:fixed;color:var(--ink);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;font-size:16px;line-height:1.5;-webkit-text-size-adjust:100%}
  .wrap{max-width:780px;margin:0 auto;padding:14px 16px 116px}
  header{padding:8px 2px 2px}
  header h1{margin:0;font-size:21px;font-weight:800;letter-spacing:-.02em;text-align:center}
  .badges{display:flex;gap:7px;justify-content:center;flex-wrap:wrap;margin-top:9px}
  .pill{display:inline-flex;align-items:center;gap:5px;font-size:11.5px;padding:5px 11px;border-radius:999px;font-weight:700;border:1px solid var(--line);background:var(--card)}
  .pill.ok{background:var(--gds);color:var(--gd-ink);border-color:transparent}
  .pill.warn{background:var(--wns);color:var(--wn);border-color:transparent}
  nav.tabs{position:fixed;left:50%;transform:translateX(-50%);bottom:14px;z-index:30;width:min(560px,calc(100% - 24px));display:flex;gap:3px;padding:7px;border-radius:22px;border:1px solid var(--line);background:var(--card);box-shadow:var(--shadow)}
  @supports (backdrop-filter:blur(1px)){nav.tabs{background:color-mix(in srgb,var(--card) 80%,transparent);backdrop-filter:saturate(150%) blur(16px);-webkit-backdrop-filter:saturate(150%) blur(16px)}}
  nav.tabs button{flex:1;border:none;background:none;cursor:pointer;padding:8px 2px;border-radius:15px;display:flex;flex-direction:column;align-items:center;gap:3px;font-size:10.5px;font-weight:700;color:var(--mut);transition:color .2s,background .2s}
  nav.tabs button .ic{font-size:18px;line-height:1;transition:transform .2s}
  nav.tabs button.active{color:#fff;background:var(--grad);box-shadow:0 8px 18px -8px rgba(59,91,255,.7)}
  nav.tabs button.active .ic{transform:translateY(-1px) scale(1.08)}
  section.tab{display:none}
  section.tab.active{display:block;animation:rise .3s ease}
  @keyframes rise{from{opacity:0;transform:translateY(9px)}to{opacity:1;transform:none}}
  h2{font-size:12px;margin:22px 4px 11px;color:var(--mut);text-transform:uppercase;letter-spacing:.09em;font-weight:800;display:flex;align-items:center;gap:8px}
  h2::before{content:"";width:15px;height:3px;border-radius:3px;background:var(--grad)}
  .card{background:var(--card);border:1px solid var(--line);border-radius:var(--r);padding:16px;margin-bottom:14px;box-shadow:var(--shadow-s)}
  .hero{position:relative;overflow:hidden;text-align:center;color:#fff;border:none;background:var(--grad);box-shadow:0 18px 44px -18px rgba(59,91,255,.7);padding:22px 18px 58px}
  .hero .eyebrow{font-size:11.5px;font-weight:700;letter-spacing:.14em;text-transform:uppercase;opacity:.85;position:relative;z-index:2}
  .hero .cd{font-size:33px;font-weight:800;letter-spacing:-.02em;margin-top:4px;line-height:1.08;position:relative;z-index:2}
  .hero .big{opacity:.92;font-size:13.5px;margin-top:7px;position:relative;z-index:2}
  .hero .sun{position:absolute;top:14px;right:18px;width:46px;height:46px;border-radius:50%;background:radial-gradient(circle at 50% 50%,#fff,rgba(255,255,255,.25));opacity:.45;z-index:1}
  .hero .mtn{position:absolute;left:0;right:0;bottom:-1px;width:100%;height:62px;display:block;z-index:1}
  .kpis{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-top:14px}
  .kpi{background:var(--card);border:1px solid var(--line);border-radius:var(--r-s);padding:14px;box-shadow:var(--shadow-s);display:flex;flex-direction:column;gap:7px}
  .kpi .ki{width:34px;height:34px;border-radius:11px;display:flex;align-items:center;justify-content:center;font-size:17px;background:var(--acs)}
  .kpi .v{font-size:20px;font-weight:800;letter-spacing:-.01em;color:var(--ink)}
  .kpi .l{font-size:11.5px;color:var(--mut);line-height:1.35}
  .lead{background:var(--gds);border:1px solid transparent;border-radius:var(--r-s);padding:13px 15px;font-size:14px;color:var(--ink-soft)}
  .lead .t{display:block;font-size:11px;color:var(--gd-ink);font-weight:800;text-transform:uppercase;letter-spacing:.06em;margin-bottom:3px}
  table{width:100%;border-collapse:collapse;font-size:14px}
  th,td{padding:9px 6px;text-align:left;border-top:1px solid var(--line);vertical-align:top}
  th{color:var(--mut);font-weight:700;font-size:11px;text-transform:uppercase;letter-spacing:.04em;border-top:none}
  .num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
  .dir{color:var(--mut);font-size:12px}
  .muted,.mut{color:var(--mut)} .gd{color:var(--gd-ink);font-weight:700} .bad{color:var(--bad);font-weight:700}
  .zona{background:var(--card-2);border:1px solid var(--line);border-radius:var(--r-s);padding:14px;margin-bottom:12px}
  .zona:last-child{margin-bottom:0}
  .zona-n{font-weight:800;font-size:14.5px;margin-bottom:8px;letter-spacing:-.01em}
  .zona-top{display:flex;justify-content:space-between;align-items:center;gap:12px}
  .zona-sub{font-size:14px;font-weight:600} .zona-meta{color:var(--mut);font-size:12.5px;margin-top:3px}
  .precio{font-size:21px;font-weight:800;color:var(--gd-ink);white-space:nowrap;line-height:1}
  .precio span{font-size:11px;font-weight:700;color:var(--mut);margin-left:2px}
  .maplink{display:inline-flex;align-items:center;gap:4px;margin-top:9px;color:var(--ac);font-weight:700;font-size:12.5px;text-decoration:none;background:var(--acs);padding:6px 11px;border-radius:999px}
  .vermas{margin-top:10px;background:none;border:1px solid var(--line);color:var(--ac);font-weight:700;font-size:12.5px;cursor:pointer;padding:6px 13px;border-radius:999px}
  .mas{display:none;margin-top:8px} .zona.show .mas{display:block} .zona.show .vermas{background:var(--acs);border-color:transparent}
  .dia{background:var(--card);border:1px solid var(--line);border-radius:var(--r-s);margin-bottom:10px;overflow:hidden;transition:box-shadow .2s}
  .dia.open{box-shadow:var(--shadow-s)}
  .dia-h{width:100%;background:none;border:none;padding:15px 16px;display:flex;justify-content:space-between;align-items:center;gap:12px;cursor:pointer;text-align:left}
  .dia-f{font-weight:800;font-size:14.5px;letter-spacing:-.01em} .dia-t{color:var(--mut);font-size:12.5px;margin-top:3px;line-height:1.35}
  .chev{font-size:15px;color:#fff;background:var(--grad);width:26px;height:26px;min-width:26px;border-radius:50%;display:flex;align-items:center;justify-content:center;transition:transform .25s}
  .dia.open .chev{transform:rotate(90deg)}
  .dia-b{display:none;padding:0 16px 16px} .dia.open .dia-b{display:block}
  .dia-b p{margin:9px 0;font-size:14px;color:var(--ink-soft)}
  .lab{display:inline-block;background:var(--acs);color:var(--ac-ink);font-size:10px;font-weight:800;text-transform:uppercase;letter-spacing:.05em;padding:3px 8px;border-radius:7px;margin-right:7px}
  .comidas{margin-top:12px;border-top:1px dashed var(--line);padding-top:12px;display:flex;flex-direction:column;gap:6px;font-size:12.5px;color:var(--mut)}
  .hero2{position:relative;overflow:hidden;text-align:center;color:#fff;border:none;background:var(--grad-gd);box-shadow:0 18px 44px -20px rgba(15,174,110,.7)}
  .hero2 .v{font-size:30px;font-weight:800;letter-spacing:-.01em} .hero2 .l{opacity:.94;font-size:12.5px;margin-top:4px}
  .addrow{display:flex;flex-wrap:wrap;gap:8px;margin:12px 0}
  input,select{font-size:15px;border:1px solid var(--line);border-radius:12px;padding:11px;background:var(--card);color:var(--ink);font-family:inherit}
  input:focus,select:focus{outline:none;border-color:var(--ac);box-shadow:0 0 0 3px var(--acs)}
  .addrow input.con{flex:1;min-width:130px} .addrow input.imp{width:88px;text-align:right}
  button.add{background:var(--grad);color:#fff;border:none;border-radius:12px;padding:0 16px;min-width:48px;font-weight:800;font-size:18px;line-height:1;cursor:pointer;box-shadow:0 8px 16px -8px rgba(59,91,255,.7)}
  button.add:active{transform:scale(.95)}
  .line{display:flex;align-items:center;gap:10px;padding:11px 2px;border-top:1px solid var(--line)}
  .line:first-child{border-top:none}
  .line .gc{flex:1;font-size:14px} .line .gv{font-weight:800;white-space:nowrap;font-variant-numeric:tabular-nums}
  .line select.own{padding:7px 8px;font-size:12.5px}
  .line .gx{background:var(--bads);border:none;color:var(--bad);font-size:16px;cursor:pointer;width:28px;height:28px;min-width:28px;border-radius:9px;line-height:1}
  .hint{font-size:13px;color:var(--mut);margin:0 0 8px;line-height:1.5}
  .fold>summary{cursor:pointer;font-weight:800;font-size:13.5px;color:var(--ac);list-style:none;display:flex;align-items:center;gap:9px}
  .fold>summary::-webkit-details-marker{display:none}
  .fold>summary::before{content:"+";display:inline-flex;width:21px;height:21px;align-items:center;justify-content:center;background:var(--acs);border-radius:7px;color:var(--ac-ink)}
  .fold[open]>summary::before{content:"\2212"}
  .fold[open]>summary{margin-bottom:10px}
  .tag{font-size:10.5px;font-weight:800;padding:3px 9px;border-radius:999px;background:var(--acs);color:var(--ac-ink);white-space:nowrap}
  .tag.comun{background:var(--line-2);color:var(--mut)}
  .prog{height:9px;background:var(--line);border-radius:999px;overflow:hidden;margin:8px 0 14px}
  .prog div{height:100%;background:var(--grad-gd);width:0;transition:width .3s ease;border-radius:999px}
  .done{opacity:.42;text-decoration:line-through}
  .chk-item{display:flex;align-items:center;gap:12px;padding:12px 2px;border-top:1px solid var(--line)}
  .chk-item:first-child{border-top:none}
  .chk-item input[type=checkbox]{width:22px;height:22px;flex:none;accent-color:var(--gd)}
  .chk-item .txt{flex:1;font-size:14.5px}
  .chips{display:flex;gap:7px;flex-wrap:wrap;margin-bottom:12px}
  .chips button{border:1px solid var(--line);background:var(--card);color:var(--mut);border-radius:999px;padding:7px 14px;font-size:12.5px;cursor:pointer;font-weight:700;transition:background .15s,color .15s}
  .chips button.on{background:var(--grad);color:#fff;border-color:transparent;box-shadow:0 8px 16px -10px rgba(59,91,255,.7)}
  .wgrid{display:grid;grid-template-columns:repeat(4,1fr);gap:9px}
  .wday{background:var(--card-2);border:1px solid var(--line);border-radius:13px;padding:10px 4px;text-align:center}
  .wday.off{opacity:.55} .wd-f{font-size:11.5px;font-weight:800} .wd-i{font-size:22px;margin:3px 0} .wd-t{font-size:11.5px;font-weight:700} .wd-r{font-size:9.5px;color:var(--mut)}
  .sitio{display:flex;justify-content:space-between;align-items:center;padding:13px 2px;border-top:1px solid var(--line);color:var(--ink);text-decoration:none;font-size:14px;font-weight:700}
  .sitio:first-child{border-top:none} .sitio span{color:var(--ac);font-size:20px;font-weight:800}
  textarea{width:100%;border:1px solid var(--line);border-radius:12px;padding:12px;font-family:inherit;font-size:15px;min-height:120px;resize:vertical;background:var(--card);color:var(--ink)}
  textarea:focus{outline:none;border-color:var(--ac);box-shadow:0 0 0 3px var(--acs)}
  .grupo{font-size:11px;font-weight:800;color:var(--ac-ink);text-transform:uppercase;letter-spacing:.06em;margin:16px 0 2px}
  .grupo:first-of-type{margin-top:4px}
  .reset{background:var(--card);border:1px solid var(--line);color:var(--mut);border-radius:10px;padding:8px 13px;font-size:12.5px;cursor:pointer;font-weight:700}
  body.editing .ed{outline:1px dashed var(--ac);background:var(--acs);border-radius:5px;padding:0 3px}
  body.editing .ed:focus{outline:2px solid var(--ac);background:var(--card)}
  .trip{position:relative}
  .jday{display:flex;gap:12px}
  .jnode{flex:none;width:30px;display:flex;flex-direction:column;align-items:center}
  .jdot{width:30px;height:30px;border-radius:50%;background:var(--grad);color:#fff;font-weight:800;font-size:13px;display:flex;align-items:center;justify-content:center;box-shadow:0 6px 14px -6px rgba(59,91,255,.6)}
  .jdot.hoy{background:var(--grad-gd);box-shadow:0 0 0 3px var(--gds),0 6px 14px -6px rgba(15,174,110,.7)}
  .jnode::after{content:"";flex:1;width:2px;background:var(--line);margin-top:4px}
  .jday:last-child .jnode::after{display:none}
  .jcard{flex:1;min-width:0;background:var(--card);border:1px solid var(--line);border-radius:var(--r-s);margin-bottom:12px;overflow:hidden;box-shadow:var(--shadow-s)}
  .jcard.open{box-shadow:var(--shadow)}
  .jhead{width:100%;background:none;border:none;cursor:pointer;text-align:left;padding:13px 14px;display:flex;align-items:center;gap:10px}
  .jmeta{flex:1;min-width:0}
  .jdate{font-size:11px;font-weight:800;color:var(--mut);text-transform:uppercase;letter-spacing:.05em;display:flex;align-items:center;gap:6px}
  .jtitle{font-weight:800;font-size:15px;letter-spacing:-.01em;margin-top:1px}
  .jteaser{color:var(--mut);font-size:12.5px;margin-top:2px;line-height:1.35}
  .jcard.open .jteaser{display:none}
  .jright{display:flex;align-items:center;gap:8px;flex:none}
  .jwx{font-size:12.5px;font-weight:700;color:var(--mut);white-space:nowrap}
  .hoytag{background:var(--grad-gd);color:#fff;font-size:9px;font-weight:800;padding:2px 7px;border-radius:999px;letter-spacing:.04em}
  .jbody{display:none;padding:0 14px 14px}
  .jcard.open .jbody{display:block}
  .seg{font-size:14px;margin:10px 0;color:var(--ink-soft);line-height:1.5}
  .seg-t{display:inline-block;background:var(--acs);color:var(--ac-ink);font-size:10px;font-weight:800;text-transform:uppercase;letter-spacing:.05em;padding:3px 8px;border-radius:7px;margin-right:7px}
  .dline{display:flex;align-items:center;gap:11px;padding:11px 12px;margin:8px 0;background:var(--card-2);border:1px solid var(--line);border-radius:12px;text-decoration:none;color:var(--ink)}
  .dline.gas{background:var(--gds);border-color:transparent}
  .dline-ic{font-size:18px;flex:none;width:24px;text-align:center}
  .dline-tx{flex:1;min-width:0;display:flex;flex-direction:column;font-size:13.5px;font-weight:700}
  .dline-tx small{font-weight:600;color:var(--mut);font-size:11.5px}
  .dline-v{font-weight:800;text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums;display:flex;flex-direction:column;font-size:15px;color:var(--gd-ink)}
  .dline-v small{font-weight:700;color:var(--mut);font-size:10px}
  .meals{margin-top:12px;border-top:1px dashed var(--line);padding-top:10px;display:flex;flex-direction:column;gap:9px}
  .meal{font-size:13.5px;display:flex;flex-direction:column;gap:1px;color:var(--ink-soft)}
  .meal-l{font-size:10.5px;font-weight:800;color:var(--mut);text-transform:uppercase;letter-spacing:.04em}
  .dsites{margin-top:12px;border-top:1px dashed var(--line);padding-top:8px}
  .dsites-t{font-size:10.5px;font-weight:800;color:var(--ac-ink);text-transform:uppercase;letter-spacing:.05em;margin-bottom:2px}
  .dsite{display:flex;justify-content:space-between;align-items:center;padding:9px 0;border-top:1px solid var(--line);color:var(--ink);text-decoration:none;font-size:13.5px;font-weight:700}
  .dsite:first-of-type{border-top:none} .dsite span{color:var(--ac);font-size:18px}
  .hoy.spot{border-color:var(--ac)}
  .hoy-eyebrow{font-size:11px;font-weight:800;color:var(--ac-ink);text-transform:uppercase;letter-spacing:.07em}
  .hoy-title{font-size:18px;font-weight:800;letter-spacing:-.01em;margin-top:3px}
  .hoy-teaser{color:var(--ink-soft);font-size:13.5px;margin-top:4px;line-height:1.4}
  .hoy-line{font-size:13px;color:var(--mut);margin-top:7px;font-weight:600}
  .hoy-btn{margin-top:12px;background:var(--grad);color:#fff;border:none;border-radius:11px;padding:10px 16px;font-weight:800;font-size:13.5px;cursor:pointer;box-shadow:0 8px 16px -8px rgba(59,91,255,.6)}
  .rings{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-top:12px}
  .ring{position:relative}
  .ring svg{width:62px;height:62px;display:block;margin:0 auto}
  .ring-bg{fill:none;stroke:var(--line);stroke-width:5}
  .ring-fg{fill:none;stroke:var(--gd);stroke-width:5;stroke-linecap:round;stroke-dasharray:113.1;stroke-dashoffset:113.1;transform:rotate(-90deg);transform-origin:50% 50%;transition:stroke-dashoffset .5s ease}
  .ring-c{position:absolute;top:0;left:0;right:0;height:62px;display:flex;align-items:center;justify-content:center;font-size:12.5px;font-weight:800}
  .ring-l{font-size:11px;color:var(--mut);font-weight:700;text-align:center;margin-top:2px}
  footer{text-align:center;color:var(--mut);font-size:12px;margin-top:22px;padding:0 8px}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>$(HtmlEnc $Data.titulo)</h1>
    <div class="badges">$apiBadge <span id="syncBadge"></span></div>
  </header>

  <!-- INICIO -->
  <section id="t-inicio" class="tab active">
    <div class="card hero">
      <div class="sun"></div>
      <div class="eyebrow">$(HtmlEnc $Data.fechas)</div>
      <div class="cd">$diasTxt</div>
      <div class="big">$(HtmlEnc $Data.coche.modelo) &middot; Gasolina 95</div>
      <svg class="mtn" viewBox="0 0 780 62" preserveAspectRatio="none" xmlns="http://www.w3.org/2000/svg"><path d="M0,62 L0,34 L90,12 L180,36 L270,6 L370,38 L470,16 L560,40 L650,10 L730,34 L780,20 L780,62 Z" fill="rgba(255,255,255,.16)"/><path d="M0,62 L0,48 L120,28 L220,48 L320,24 L430,50 L540,30 L650,48 L740,30 L780,44 L780,62 Z" fill="rgba(255,255,255,.28)"/></svg>
    </div>
    $($hoyHtml.ToString())
    <div class="kpis">
      <div class="kpi"><span class="ki">&#128663;</span><div class="v">$autonomia km</div><div class="l">autonomia deposito lleno</div></div>
      <div class="kpi"><span class="ki">&#128176;</span><div class="v">$($costeIdaVuelta.ToString('0',$INV)) &euro;</div><div class="l">gasolina ida y vuelta aprox</div></div>
      <div class="kpi"><span class="ki">&#128197;</span><div class="v">8</div><div class="l">dias de viaje</div></div>
      <div class="kpi"><span class="ki">&#9981;</span><div class="v">$($refPrice.ToString('0.000',$INV))</div><div class="l">&euro;/L mas barato ruta</div></div>
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
    <div class="card" style="display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap">
      <span class="hint" style="margin:0">El viaje dia a dia. Toca un dia para ver su <b>plan, gasolinera, tiempo, comidas y sitios</b> juntos. Con <b>Editar</b> cambias los textos (se sincroniza con tu copiloto).</span>
      <span style="display:flex;gap:8px"><button id="resetEdit" class="reset" style="display:none;margin:0" onclick="resetEdits()">Restaurar</button><button id="editBtn" class="add" style="padding:8px 14px" onclick="toggleEdit()">&#9999;&#65039; Editar</button></span>
    </div>
    $($itinHtml.ToString())
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
const FB_CFG = __FIREBASE__;
const eur = n => (Math.round(n*100)/100).toLocaleString('es-ES',{minimumFractionDigits:2,maximumFractionDigits:2});
const load=(k,def)=>{ try{ const v=JSON.parse(localStorage.getItem(k)); return (v===null||v===undefined)?def:v; }catch(e){ return def; } };

/* Almacen compartido: Firebase si hay config; si no, solo este dispositivo */
let DB=null;
try{ if(FB_CFG && FB_CFG.databaseURL && typeof firebase!=='undefined'){ firebase.initializeApp(FB_CFG); DB=firebase.database().ref('viaje'); } }catch(e){ DB=null; }
function bind(key, apply, seed){
  if(DB){
    DB.child(key).on('value', function(s){
      var raw=s.val(), v;
      if(raw===null||raw===undefined){ v=seed; try{ DB.child(key).set(JSON.stringify(seed)); }catch(e){} }
      else { try{ v=JSON.parse(raw); }catch(e){ v=seed; } }
      apply(v);
    });
  } else { apply(load('viajeAmieva_'+key, seed)); }
}
function persist(key, value){
  if(DB){ try{ DB.child(key).set(JSON.stringify(value)); }catch(e){} }
  else { localStorage.setItem('viajeAmieva_'+key, JSON.stringify(value)); }
}
function setSync(t,on){ var b=document.getElementById('syncBadge'); if(b){ b.innerHTML=t; b.className='pill '+(on?'ok':'warn'); } }
if(DB){
  setSync('&#9679; sincronizando...', false);
  firebase.database().ref('.info/connected').on('value', function(s){ setSync(s.val()?'&#9679; sincronizado':'&#9679; sin conexion', !!s.val()); });
}

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
function setRing(id,vid,done,total){
  var C=113.1, c=document.getElementById(id);
  if(c){ c.style.strokeDashoffset = C*(1-(total?done/total:0)); }
  var t=document.getElementById(vid); if(t){ t.textContent=done+'/'+total; }
}
function irAlDia(i){
  var b=document.querySelector("nav.tabs button:nth-child(4)"); if(b){ showTab('t-plan',b); }
  var c=document.getElementById('jday'+i);
  if(c){ c.classList.add('open'); setTimeout(function(){ c.scrollIntoView({behavior:'smooth',block:'start'}); },80); }
}

/* ---- Gasolina (la pone PAGADOR, se divide entre todos) ---- */
let repos = [];
function saveGas(){ persist('gastos', repos); }
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
let shared = [];
function saveSh(){ persist('shared', shared); }
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
let maleta = [];
let filtro='Todos';
function saveMal(){ persist('maleta', maleta); }
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
  setRing('ring-mal','rv-mal',maleta.filter(function(m){return m.ok;}).length,maleta.length);
}

/* ---- Compra (lista del viaje, agrupada y marcable) ---- */
let compra = [];
function saveCom(){ persist('compra', compra); }
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
  setRing('ring-com','rv-com',done,compra.length);
}

/* ---- Antes de salir (reservas) ---- */
let reservas = [];
function saveRes(){ persist('reservas', reservas); }
function toggleRes(i){ reservas[i].ok=!reservas[i].ok; saveRes(); renderRes(); }
function renderRes(){
  const list=document.getElementById('res-list'); list.innerHTML='';
  reservas.forEach((r,i)=>{
    const row=document.createElement('div'); row.className='chk-item';
    row.innerHTML='<input type="checkbox" '+(r.ok?'checked':'')+' onchange="toggleRes('+i+')">'+
      '<span class="txt '+(r.ok?'done':'')+'">'+r.item+'</span>';
    list.appendChild(row);
  });
  setRing('ring-res','rv-res',reservas.filter(function(r){return r.ok;}).length,reservas.length);
}

/* ---- Notas ---- */
const ta=document.getElementById('notas');
ta.addEventListener('input', ()=>persist('notas', ta.value));

/* ---- Editar textos del plan (compartido) ---- */
let editing=false, edits={};
function applyEdits(){ document.querySelectorAll('.ed').forEach(e=>{ const v=edits[e.dataset.k]; if(v!=null && document.activeElement!==e) e.innerText=v; }); }
function toggleEdit(){
  editing=!editing;
  document.querySelectorAll('.ed').forEach(e=>{ e.contentEditable = editing?'true':'false'; });
  document.body.classList.toggle('editing', editing);
  document.getElementById('editBtn').innerHTML = editing ? '&#10003; Hecho' : '&#9999;&#65039; Editar';
  document.getElementById('resetEdit').style.display = editing ? '' : 'none';
}
document.addEventListener('input', e=>{ const t=e.target; if(t.classList && t.classList.contains('ed')){ edits[t.dataset.k]=t.innerText; persist('edits', edits); } });
function resetEdits(){ if(confirm('Borrar los cambios del plan y volver al original?')){ edits={}; persist('edits', edits); location.reload(); } }

/* Arranque: enlaza cada parte al almacen (Firebase o local) */
renderComida();
bind('gastos',   function(v){ repos=Array.isArray(v)?v:[]; renderGas(); },     []);
bind('shared',   function(v){ shared=Array.isArray(v)?v:[]; renderSh(); },      []);
bind('maleta',   function(v){ maleta=Array.isArray(v)?v:[]; renderMaleta(); },  SEED_CHECK.map(x=>({item:x,quien:'Comun',ok:false})));
bind('compra',   function(v){ compra=Array.isArray(v)?v:[]; renderCompra(); },  SEED_COMPRA.map(x=>({item:x.item,grupo:x.grupo,ok:false})));
bind('reservas', function(v){ reservas=Array.isArray(v)?v:[]; renderRes(); },   SEED_RESERVAS.map(x=>({item:x,ok:false})));
bind('notas',    function(v){ if(document.activeElement!==ta) ta.value=(typeof v==='string')?v:''; }, '');
bind('edits',    function(v){ edits=(v&&typeof v==='object'&&!Array.isArray(v))?v:{}; applyEdits(); }, {});
</script>
'@

  # Firebase: si datos.json trae config con databaseURL, se inyecta el SDK y la config
  $fbCfg = $null
  if ($Data.PSObject.Properties['firebase']) { $fbCfg = $Data.firebase }
  $fbOk = ($fbCfg -and $fbCfg.PSObject.Properties['databaseURL'] -and "$($fbCfg.databaseURL)".Trim() -ne '')
  $fbJs = if ($fbOk) { ($fbCfg | ConvertTo-Json -Compress) } else { 'null' }
  $fbScripts = if ($fbOk) {
    '<script src="https://www.gstatic.com/firebasejs/10.12.5/firebase-app-compat.js"></script>' +
    '<script src="https://www.gstatic.com/firebasejs/10.12.5/firebase-database-compat.js"></script>'
  } else { '' }

  $script = $script.Replace('__VIAJEROS__', $viajerosJs).Replace('__CHECK__', $checklistJs).Replace('__RESERVAS__', $reservasJs).Replace('__COMPRA__', $compraJs).Replace('__PAGADOR__', ($pagador | ConvertTo-Json)).Replace('__FIREBASE__', $fbJs)
  $full = $html + "`r`n" + $fbScripts + "`r`n" + $script + "`r`n</body>`r`n</html>`r`n"
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

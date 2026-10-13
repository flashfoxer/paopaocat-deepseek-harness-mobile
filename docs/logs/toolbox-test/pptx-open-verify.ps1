# 用真实 PowerPoint（COM 自动化）打开生成的 pptx：能打开=最强证据；再逐页导出 PNG + 读回文字
$ErrorActionPreference = 'Stop'
$pptx = $args[0]
$outDir = $args[1]
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$app = $null
$pres = $null
try {
  $app = New-Object -ComObject PowerPoint.Application
  $app.DisplayAlerts = 1          # ppAlertsNone
  Write-Output "powerpoint version = $($app.Version)"
  $pres = $app.Presentations.Open($pptx, $true, $false, $false)   # ReadOnly, Untitled, WithWindow=false
  Write-Output "opened = OK"
  Write-Output "slides = $($pres.Slides.Count)"
  Write-Output "page size = $($pres.PageSetup.SlideWidth) x $($pres.PageSetup.SlideHeight)"
  for ($i = 1; $i -le $pres.Slides.Count; $i++) {
    $s = $pres.Slides.Item($i)
    Write-Output "--- slide $i (shapes=$($s.Shapes.Count)) ---"
    for ($j = 1; $j -le $s.Shapes.Count; $j++) {
      $sh = $s.Shapes.Item($j)
      $t = ''
      try { if ($sh.HasTextFrame -eq -1 -and $sh.TextFrame.HasText -eq -1) { $t = $sh.TextFrame.TextRange.Text } } catch { $t = '<no text>' }
      Write-Output ("  shape[$j] ph=$($sh.PlaceholderFormat.Type) text=" + ($t -replace "`r", ' | '))
    }
    $np = $s.NotesPage
    for ($k = 1; $k -le $np.Shapes.Count; $k++) {
      $sh = $np.Shapes.Item($k)
      try {
        if ($sh.HasTextFrame -eq -1 -and $sh.TextFrame.HasText -eq -1 -and $sh.PlaceholderFormat.Type -eq 2) {
          Write-Output ("  NOTES = " + ($sh.TextFrame.TextRange.Text -replace "`r", ' | '))
        }
      } catch { }
    }
    # 导出 PNG：证明真的渲染出来了
    $png = Join-Path $outDir ("slide$i.png")
    $s.Export($png, 'PNG', 1280, 720)
    if (Test-Path $png) { Write-Output "  exported $png ($((Get-Item $png).Length) bytes)" }
  }
  # 另存为 PDF：走完整渲染管线
  $pdf = Join-Path $outDir 'out.pdf'
  $pres.SaveAs($pdf, 32)   # ppSaveAsPDF
  Write-Output "pdf = $(Test-Path $pdf) size=$((Get-Item $pdf -ErrorAction SilentlyContinue).Length)"
}
finally {
  if ($pres) { try { $pres.Close() } catch {} }
  if ($app) { try { $app.Quit() } catch {} }
  [System.Runtime.InteropServices.Marshal]::ReleaseComObject($app) 2>$null | Out-Null
}

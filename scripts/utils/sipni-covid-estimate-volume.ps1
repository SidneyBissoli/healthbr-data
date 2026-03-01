$hash = "f58e39ef-bcdd-4fc4-bae5-f3c5a2858afe"
$base = "https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/SIPNI/COVID/uf"
$ufs = @("AC","AL","AM","AP","BA","CE","DF","ES","GO","MA","MG","MS","MT","PA","PB","PE","PI","PR","RJ","RN","RO","RR","RS","SC","SE","SP","TO")
$total = 0
foreach ($uf in $ufs) {
    $ufTotal = 0
    for ($p = 0; $p -le 4; $p++) {
        $part = $p.ToString("D5")
        $url = "$base/uf%3D$uf/part-$part-$hash.c000.csv"
        $headers = curl -sI $url 2>$null
        $match = $headers | Select-String "Content-Length:\s*(\d+)"
        if ($match) { $len = [long]$match.Matches[0].Groups[1].Value; $ufTotal += $len }
    }
    $gb = [math]::Round($ufTotal / 1GB, 2)
    $total += $ufTotal
    Write-Host "$uf : $gb GB"
}
Write-Host "`nTOTAL: $([math]::Round($total / 1GB, 2)) GB"
# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.4
param(
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][ValidateSet('success','http-error','timeout','cancellation')][string]$Mode,
    [Parameter(Mandatory)][string]$ReadyPath,
    [Parameter(Mandatory)][string]$AssetName,
    [Parameter(Mandatory)][string]$AssetSha256,
    [Parameter(Mandatory)][string]$Sentinel
)
$ErrorActionPreference='Stop'
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
function Write-Response($Stream,[int]$Status,[byte[]]$Body,[switch]$Slow){
    $reason=if($Status-eq200){'OK'}else{'Error'}
    $header=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $Status $reason`r`nContent-Length: $($Body.Length)`r`nConnection: close`r`n`r`n")
    $Stream.Write($header,0,$header.Length);$Stream.Flush()
    if($Slow){
        for($offset=0;$offset-lt$Body.Length;$offset+=128){$length=[Math]::Min(128,$Body.Length-$offset)
            $Stream.Write($Body,$offset,$length);$Stream.Flush();Start-Sleep -Milliseconds 75}
    }else{$Stream.Write($Body,0,$Body.Length);$Stream.Flush()}
}
try{
    $listener.Start()
    [IO.File]::WriteAllText($ReadyPath,'ready',[Text.UTF8Encoding]::new($false))
    $requestLimit=if($Mode-in@('success','cancellation')){3}else{1}
    for($requestIndex=0;$requestIndex-lt$requestLimit;$requestIndex++){
        $client=$listener.AcceptTcpClient()
        try{
            $stream=$client.GetStream();$reader=[IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$false,1024,$true)
            $requestLine=$reader.ReadLine();while(-not[string]::IsNullOrEmpty($reader.ReadLine())){}
            $path=($requestLine-split' ')[1]
            if($Mode-eq'http-error'){Write-Response $stream 500 ([Text.UTF8Encoding]::new($false).GetBytes($Sentinel));continue}
            if($Mode-eq'timeout'){Start-Sleep -Seconds 3;continue}
            if($path-eq'/metadata'){
                $base="http://127.0.0.1:$Port"
                $json=[ordered]@{draft=$false;prerelease=$false;tag_name='v7.99.1';assets=@(
                    [ordered]@{name=$AssetName;browser_download_url="$base/asset"},
                    [ordered]@{name='hashes.sha256';browser_download_url="$base/hashes"})}|ConvertTo-Json -Depth 5 -Compress
                Write-Response $stream 200 ([Text.UTF8Encoding]::new($false).GetBytes($json));continue
            }
            if($path-eq'/hashes'){
                $text=if($Mode-eq'cancellation'){($Sentinel+('x'*32768))}else{"$AssetSha256  $AssetName`n"}
                Write-Response $stream 200 ([Text.UTF8Encoding]::new($false).GetBytes($text)) -Slow:($Mode-eq'cancellation');continue
            }
            Write-Response $stream 200 ([Text.UTF8Encoding]::new($false).GetBytes('fixture archive'))
        }finally{if($null-ne$reader){$reader.Dispose()};$client.Dispose()}
    }
}finally{$listener.Stop()}

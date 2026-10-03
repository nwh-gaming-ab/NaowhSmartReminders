# Rebuild the bundled English clips on Windows with System.Speech and ffmpeg.
param([string]$VoiceName = 'Microsoft Zira Desktop', [string[]]$Only)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech
$voiceOutput = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../Media/Voice'))
New-Item -ItemType Directory -Force -Path $voiceOutput | Out-Null
$clips = [ordered]@{
    'dispel-me' = 'Dispel me.'
    'move-out' = 'Move out.'
    'use-a-defensive' = 'Use a defensive.'
    'stoneform-ready' = 'Stoneform.'
    'stoneform-preview' = 'Stoneform.'
}
$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
try {
    $synth.SelectVoice($VoiceName)
    $synth.Rate = 1
    $synth.Volume = 100
    foreach ($clip in $clips.GetEnumerator()) {
        if ($Only -and $clip.Key -notin $Only) { continue }
        $temporaryWave = [IO.Path]::GetTempFileName()
        try {
            $synth.SetOutputToWaveFile($temporaryWave)
            $synth.Speak($clip.Value)
            $synth.SetOutputToNull()
            $destination = Join-Path $voiceOutput ($clip.Key + '.ogg')
            & ffmpeg -hide_banner -loglevel error -y -i $temporaryWave -map_metadata -1 -af 'silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.03,loudnorm=I=-18:TP=-2:LRA=7' -ac 1 -ar 44100 -c:a libvorbis -q:a 4 $destination
            if ($LASTEXITCODE -ne 0) { throw "Encoding failed: $destination" }
        } finally {
            Remove-Item -LiteralPath $temporaryWave -ErrorAction SilentlyContinue
        }
    }
} finally {
    $synth.Dispose()
}

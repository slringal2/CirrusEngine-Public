#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Pack,
    [string]$BookTitle = '積雲の観察と描画',
    [string[]]$ChapterOrder
)

$ErrorActionPreference = 'Stop'
$root = (Get-Item -LiteralPath $Pack -ErrorAction Stop)
if (-not $root.PSIsContainer) { throw "Pack must be a directory: $Pack" }
$rootPath = $root.FullName
# An explicit file URI keeps URL fragments and % escapes distinct from Windows path characters.
function File-Uri([string]$Path) { [uri]::new(([uri]::new($Path)).AbsoluteUri) }
$rootUri = File-Uri ($rootPath.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar)

# Load the Markdig assembly shipped with PowerShell. Its GitHub heading IDs retain Japanese.
$null = ConvertFrom-Markdown -InputObject 'init'
$builder = [Markdig.MarkdownPipelineBuilder]::new()
$null = [Markdig.MarkdownExtensions]::UseAutoIdentifiers(
    $builder, [Markdig.Extensions.AutoIdentifiers.AutoIdentifierOptions]::GitHub)
$null = [Markdig.MarkdownExtensions]::UseAdvancedExtensions($builder)
$pipeline = $builder.Build()

function Escape-Html([string]$Value) { [Net.WebUtility]::HtmlEncode($Value) }
function Read-Label([string]$Markup) {
    [Net.WebUtility]::HtmlDecode([regex]::Replace($Markup, '<[^>]+>', '')).Trim()
}

$priority = @('README.md', 'observations.md', 'photo-analysis/photo-analysis.md',
              'shape-change.md', 'rendering-guide.md', 'verification-lab.md', 'temporal-check.md')
if ($ChapterOrder) { $priority = $ChapterOrder }
$files = @(Get-ChildItem -LiteralPath $rootPath -File -Recurse -Filter '*.md' |
    Select-Object FullName, @{ n = 'Relative'; e = { [IO.Path]::GetRelativePath($rootPath,$_.FullName).Replace('\','/') } } |
    Sort-Object @{ e = { $rank = [Array]::IndexOf($priority, $_.Relative); if ($rank -lt 0) { $priority.Count } else { $rank } } }, Relative)
if (-not $files.Count) { throw "No Markdown chapters found in $rootPath" }

$chapterByPath = @{}
$chapters = @(
    foreach ($file in $files) {
        $body = [Markdig.Markdown]::ToHtml([IO.File]::ReadAllText($file.FullName), $pipeline)
        $titleMatch = [regex]::Match($body, '(?is)<h1\b[^>]*>(.*?)</h1>')
        $title = if ($titleMatch.Success) { Read-Label $titleMatch.Groups[1].Value } else { $file.Relative }
        $key = 'chapter-' + (1 + $chapterByPath.Count)
        $chapter = [pscustomobject]@{
            Key = $key; Title = $title; Source = (File-Uri $file.FullName); Body = $body
        }
        $chapterByPath[$file.FullName] = $chapter
        $chapter
    }
)

# The source file's directory is the base of each relative URI, including images and PDFs.
function Resolve-BookLink([string]$Url, [uri]$Source, [bool]$IsLink) {
    if ($Url -match '^(?:[a-zA-Z][a-zA-Z0-9+.-]*:|//|/)') { return $Url }
    $resolved = [uri]::new($Source, $Url)
    $target = $chapterByPath[$resolved.LocalPath]
    if ($IsLink -and $null -ne $target -and -not $resolved.Query) {
        if ($resolved.Fragment.Length -gt 1) {
            $fragment = [uri]::UnescapeDataString($resolved.Fragment.Substring(1))
            return '#' + [uri]::EscapeDataString($target.Key + '--' + $fragment)
        }
        return '#' + $target.Key
    }
    return $rootUri.MakeRelativeUri($resolved).OriginalString
}

$tags = [regex]'(?s)<[A-Za-z][\w:-]*(?:[^<>\x22\x27]|\x22[^\x22]*\x22|\x27[^\x27]*\x27)*>'
$attributes = [regex]'(?i)(?<space>\s)(?<name>id|href|src)\s*=\s*(?<q>["''])(?<value>.*?)\k<q>'
$toc = [Text.StringBuilder]::new()
$content = [Text.StringBuilder]::new()
foreach ($chapter in $chapters) {
    $key = $chapter.Key
    $title = Escape-Html $chapter.Title
    # Namespace all IDs, including footnote references and repeated headings, before joining chapters.
    $rewritten = $tags.Replace($chapter.Body, {
        param($tag)
        $attributes.Replace($tag.Value, {
            param($attribute)
            $name = $attribute.Groups['name'].Value.ToLowerInvariant()
            $original = [Net.WebUtility]::HtmlDecode($attribute.Groups['value'].Value)
            $value = if ($name -eq 'id') {
                $chapter.Key + '--' + $original
            } else {
                Resolve-BookLink $original $chapter.Source ($name -eq 'href')
            }
            $attribute.Groups['space'].Value + $name + '="' + (Escape-Html $value) + '"'
        })
    })
    $null = $toc.AppendLine("<li><a href='#$key'>$title</a>")
    $sections = [regex]::Matches($rewritten, '(?is)<h2\b[^>]*\sid="([^"]+)"[^>]*>(.*?)</h2>')
    if ($sections.Count) {
        $null = $toc.AppendLine('<ol>')
        foreach ($section in $sections) {
            $id = [uri]::EscapeDataString([Net.WebUtility]::HtmlDecode($section.Groups[1].Value))
            $text = Escape-Html (Read-Label $section.Groups[2].Value)
            $null = $toc.AppendLine("<li><a href='#$id'>$text</a></li>")
        }
        $null = $toc.AppendLine('</ol>')
    }
    $null = $toc.AppendLine('</li>')
    $rewritten = $rewritten.Replace('<table>', '<div class="table-wrap"><table>').Replace('</table>', '</table></div>')
    $null = $content.AppendLine("<article id='$key' aria-label='$([Net.WebUtility]::HtmlEncode($chapter.Title))'>")
    $null = $content.AppendLine($rewritten)
    $null = $content.AppendLine("<p class='return'><a href='#contents'>目次に戻る</a></p></article>")
}

$css = @'
:root{color-scheme:light;--ink:#152632;--muted:#4a626a;--line:#c1d0cd;--accent:#195a5c}
*{box-sizing:border-box}
html{scroll-padding-block-start:1rem}
body{margin:0;background:#f4f6f3;color:var(--ink);font:16px/1.85 Inter,"Yu Gothic UI","Yu Gothic",Meiryo,sans-serif;overflow-wrap:anywhere}
header,main{width:min(1080px,calc(100% - 36px));margin:0 auto}
header{padding:2.4rem 0 1rem;border-bottom:2px solid var(--accent)}
header p{margin:.3rem 0}
h1,h2,h3{line-height:1.45}
header h1{font:600 clamp(1.8rem,4vw,2.75rem)/1.3 "Yu Mincho","Hiragino Mincho ProN",serif;margin:0}
a{color:#125559;text-underline-offset:.2em}
a:focus-visible{outline:3px solid #b55a17;outline-offset:3px}
nav{padding:1rem 0 1.4rem}
nav>ol{padding-left:1.6rem;columns:2;column-gap:3rem}
nav>ol>li{break-inside:avoid;margin-bottom:.6rem;font-weight:600}
nav ol ol{padding-left:1.2rem;font-weight:400;font-size:.92em;list-style:disc}
article{background:white;padding:clamp(18px,4vw,52px);border-top:2px solid var(--accent);margin:1rem 0 2rem}
article h1{font:600 clamp(1.45rem,3.2vw,2.1rem)/1.45 "Yu Mincho","Hiragino Mincho ProN",serif;margin:.15rem 0 1.1rem}
article h2{font-size:1.38rem;border-bottom:1px solid var(--line);padding-bottom:.25rem;margin:1.85rem 0 .7rem}
article h3{font-size:1.12rem;margin:1.5rem 0 .5rem}
article img{display:block;max-width:100%;height:auto;margin:.75rem auto}
.table-wrap{overflow-x:auto;margin:1rem 0}
table{border-collapse:collapse;width:100%;font-size:.93rem;text-align:left}
th,td{border:1px solid var(--line);padding:.4rem .6rem;vertical-align:top}
th{background:#e4eeea}
tbody tr:nth-child(even){background:#f5f8f6}
pre,code{font-family:Consolas,"Courier New",monospace}
code{background:#eef2ef;padding:.05em .18em}
pre{padding:.8rem 1rem;border-left:3px solid var(--accent);background:#eef2ef;line-height:1.5;overflow-x:auto}
pre code{padding:0}
blockquote{margin:1rem 0;padding:.1rem 1rem;border-left:3px solid var(--line);color:var(--muted)}
.footnotes{font-size:.88rem;color:var(--muted)}
.return{margin:2rem 0 0;font-size:.9rem}
@media(max-width:680px){nav>ol{columns:1}header,main{width:calc(100% - 24px)}article{padding:14px}}
@page{size:A4;margin:17mm 15mm 19mm}
@media print{
body{background:white;color:black;font-size:10.5pt;line-height:1.65}
header,main{width:100%;margin:0}
header{padding:0 0 3mm}
header a,.return{display:none}
nav>ol{columns:2}
a{color:inherit}
article{margin:0;padding:0;border:0;break-before:page}
h1,h2,h3,figcaption{break-after:avoid}
img{max-height:160mm;object-fit:contain;break-inside:avoid}
.table-wrap,pre{overflow:visible}
thead{display:table-header-group}
tr{break-inside:avoid}
pre,pre code{white-space:pre-wrap;overflow-wrap:anywhere}
p{orphans:3;widows:3}
}
'@
$escapedTitle = Escape-Html $BookTitle
$page = @"
<!doctype html>
<html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$escapedTitle｜CirrusEngine 技術読本</title><style>$css</style></head>
<body><header><h1>$escapedTitle</h1><p>CirrusEngine 技術読本</p><a href="index.html">画像比較に戻る</a></header>
<main><nav id="contents" aria-label="目次"><h2>目次</h2><ol>$toc</ol></nav>
$content</main></body></html>
"@
$outFile = Join-Path $rootPath 'reader.html'
$tempFile = Join-Path $rootPath ('.reader-' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
    [IO.File]::WriteAllText($tempFile, $page, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($tempFile, $outFile, $true)
} finally {
    if ([IO.File]::Exists($tempFile)) { [IO.File]::Delete($tempFile) }
}
Write-Output ("{0} chapters -> {1}" -f $chapters.Count, $outFile)

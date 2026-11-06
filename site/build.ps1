# Builds the landing page into site\public: the pages in site\src, and the
# app's logo, icons and fonts.
#
# The installers aren't hosted here: Firebase's free Spark plan refuses them.
# The download buttons and the /download links point at the files on this
# version's GitHub release instead, built by .github/workflows/build.yml, and
# the page shows the SHA-256 GitHub reports for each. That release has to be
# published first.
#
#   site\build.ps1           build only (preview with: npm run preview)
#   site\build.ps1 -Deploy   build, then publish to every site in hosting.json:
#                            the page to the main one, and to the others a
#                            permanent redirect to the same address on it
#
# Deploying uses the account the Firebase CLI is signed in with, or with
# -KeyFile <path>, a service account key for the project.
param([switch]$Deploy, [string]$KeyFile)

$site = $PSScriptRoot
$root = Split-Path -Parent $site
$public = Join-Path $site 'public'
$utf8 = New-Object System.Text.UTF8Encoding $false
$repo = 'GeorgeMilroy/Craft-Apps-Manager'

$version = (Select-String -Path "$root\Cargo.toml" -Pattern '^version = "(.+)"' | Select-Object -First 1).Matches.Groups[1].Value
$tag = "v$version"
try {
    $release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/tags/$tag" -Headers @{ Accept = 'application/vnd.github+json' }
}
catch {
    throw "There's no published $tag release on github.com/$repo. Push the $tag tag, wait for GitHub to build it, then publish the release."
}

# One installer on the release: its name, address, size and SHA-256.
function Get-Installer([string]$Name) {
    $asset = $release.assets | Where-Object name -EQ $Name | Select-Object -First 1
    if (-not $asset) { throw "The $tag release on github.com/$repo has no $Name." }
    if ($asset.digest -match '^sha256:([0-9a-f]{64})$') { $sha256 = $Matches[1] }
    else { throw "GitHub doesn't give a SHA-256 for $Name on the $tag release." }
    [pscustomobject]@{
        File   = $asset.name
        Url    = $asset.browser_download_url
        Length = [long]$asset.size
        Size   = '{0:0.0} MB' -f ($asset.size / 1MB)
        Sha256 = $sha256
    }
}
$x64 = Get-Installer "ArtCraftAppsManager-$version-x64.msi"
$x86 = Get-Installer "ArtCraftAppsManager-$version-x86.msi"
$mac = Get-Installer "ArtCraftAppsManager-$version-macos-universal.dmg"
$released = [datetime]$release.published_at

if (Test-Path $public) { Remove-Item $public -Recurse -Force }
Copy-Item "$site\src" $public -Recurse
New-Item -ItemType Directory -Force "$public\fonts", "$public\assets\apps" | Out-Null
Copy-Item "$root\assets\fonts\*" "$public\fonts"
Copy-Item "$root\assets\app-icons\*.png" "$public\assets\apps"
Copy-Item "$root\assets\logo.png" "$public\assets\logo.png"
Copy-Item "$root\assets\logo.ico" "$public\favicon.ico"

# The 64-bit Windows installer is the main download; the _x86 values are for
# 32-bit Windows and the _mac ones for macOS.
$values = @{
    version    = $version
    released   = $released.ToString('d MMMM yyyy', [Globalization.CultureInfo]::InvariantCulture)
}
foreach ($pair in @(@('', $x64), @('_x86', $x86), @('_mac', $mac))) {
    $suffix, $installer = $pair
    $values["file$suffix"] = $installer.File
    $values["url$suffix"] = $installer.Url
    $values["size$suffix"] = $installer.Size
    $values["sha256$suffix"] = $installer.Sha256
}
foreach ($page in Get-ChildItem $public -Filter *.html) {
    $html = [IO.File]::ReadAllText($page.FullName)
    foreach ($key in $values.Keys) { $html = $html.Replace("{{$key}}", $values[$key]) }
    [IO.File]::WriteAllText($page.FullName, $html, $utf8)
}

# For anything that wants the current version, such as a future self-updater.
$latest = [ordered]@{
    version  = $version
    url      = $x64.Url
    size     = $x64.Length
    sha256   = $x64.Sha256
    released = $released.ToString('yyyy-MM-dd')
    x86      = [ordered]@{ url = $x86.Url; size = $x86.Length; sha256 = $x86.Sha256 }
    mac      = [ordered]@{ url = $mac.Url; size = $mac.Length; sha256 = $mac.Sha256 }
}
[IO.File]::WriteAllText("$public\latest.json", ($latest | ConvertTo-Json), $utf8)

# firebase.json, from hosting.json: the main site with the full Hosting
# config, with /download, /download/x86 and /download/mac pointing at this
# version's files on GitHub. Each of the other sites permanently redirects every address to the
# same one on the main site, so old links keep working. (Firebase allows only
# one site per hosting entry.) Their redirect folder only has a fallback page.
$hosting = [IO.File]::ReadAllText("$site\hosting.json")
$hosting = $hosting.Replace('{{url}}', $x64.Url).Replace('{{url_x86}}', $x86.Url).Replace('{{url_mac}}', $mac.Url) | ConvertFrom-Json
$main = [ordered]@{ site = $hosting.main }
foreach ($p in $hosting.config.PSObject.Properties) { $main[$p.Name] = $p.Value }
$entries = @($main) + @(foreach ($name in $hosting.redirect) {
    [ordered]@{
        site      = $name
        public    = 'redirect'
        # Regexes rather than a "/:path*" glob, which the Hosting emulator doesn't
        # apply, so these can be tried locally too.
        redirects = @(
            [ordered]@{ regex = '^/$'; destination = "https://$($hosting.main).web.app/"; type = 301 },
            [ordered]@{ regex = '^/(.+)$'; destination = "https://$($hosting.main).web.app/:1"; type = 301 }
        )
    }
})
[IO.File]::WriteAllText("$site\firebase.json", (@{ hosting = $entries } | ConvertTo-Json -Depth 10), $utf8)

Write-Host "Built $public for version $version"

if ($Deploy) {
    $saved = $env:GOOGLE_APPLICATION_CREDENTIALS, $env:XDG_CONFIG_HOME
    Push-Location $site
    try {
        if ($KeyFile) {
            # The CLI prefers any signed-in account over a key, so give it an
            # empty settings folder to make it use the key.
            $env:GOOGLE_APPLICATION_CREDENTIALS = (Resolve-Path $KeyFile).Path
            $env:XDG_CONFIG_HOME = Join-Path ([IO.Path]::GetTempPath()) 'artcraft-site-deploy'
            New-Item -ItemType Directory -Force $env:XDG_CONFIG_HOME | Out-Null
        }
        firebase deploy --only hosting --non-interactive
        if ($LASTEXITCODE) { throw "firebase deploy failed" }
    }
    finally {
        $env:GOOGLE_APPLICATION_CREDENTIALS, $env:XDG_CONFIG_HOME = $saved
        Pop-Location
    }
}

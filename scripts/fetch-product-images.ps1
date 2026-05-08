param(
    [Parameter(Mandatory = $true)]
    [string]$SourceFile,

    [string]$OutputFile,

    [string]$ImageRoot = ".\product-images",

    [string]$ApiKey = $env:BRAVE_SEARCH_API_KEY,

    [string]$ProductColumn = "product",

    [string]$CategoryColumn = "category",

    [string]$ImagesColumn = "images",

    [string]$ProductSlugColumn = "product_slug",

    [int]$MaxImagesPerProduct = 1,

    [int]$MaxResultsToTry = 20,

    [int]$MaxProducts = 0,

    [string]$QuerySuffix = "產品 瓶身 酒瓶",

    [string]$Country = "TW",

    [string]$SearchLang = "zh-hant",

    [int]$MinScore = 30,

    [switch]$Force,

    [switch]$CandidatesOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:ImageExtensionsByContentType = @{
    "image/jpeg" = ".jpg"
    "image/jpg" = ".jpg"
    "image/png" = ".png"
    "image/webp" = ".webp"
    "image/gif" = ".gif"
    "image/avif" = ".avif"
}
$script:AllowedExtensions = @(".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif")
$script:QuoteChars = [char[]]@([char]39, [char]34, [char]96)

function Resolve-FullPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$BasePath = (Get-Location).Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function ConvertTo-Slug {
    param(
        [AllowNull()]
        [string]$Value,

        [string]$Fallback = "item"
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Fallback
    }

    $slug = $Value.Trim().ToLowerInvariant()
    $slug = [regex]::Replace($slug, '[\\/:*?""<>|]', ' ')
    $slug = [regex]::Replace($slug, "\s+", "-")
    $slug = [regex]::Replace($slug, "[^\p{L}\p{Nd}\-_]", "-")
    $slug = [regex]::Replace($slug, "-+", "-")
    $slug = $slug.Trim('-','_',' ')

    if ([string]::IsNullOrWhiteSpace($slug)) {
        return $Fallback
    }

    return $slug
}

function Get-CellValue {
    param(
        [Parameter(Mandatory = $true)]
        $Row,

        [Parameter(Mandatory = $true)]
        [string]$ColumnName
    )

    $property = $Row.PSObject.Properties | Where-Object { $_.Name -ieq $ColumnName } | Select-Object -First 1
    if (-not $property) {
        return $null
    }

    $value = [string]$property.Value
    if ($null -eq $value) {
        return $null
    }

    return $value.Trim($script:QuoteChars).Trim()
}

function Read-Utf8Csv {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
    $text = [System.IO.File]::ReadAllText($Path, $utf8Strict)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
        $text = $text.Substring(1)
    }

    return @($text | ConvertFrom-Csv)
}

function ConvertTo-CompactText {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    return ([regex]::Replace($Value, "[\s\W_]+", "")).ToLowerInvariant()
}

function Get-ResultScore {
    param(
        [Parameter(Mandatory = $true)]
        $Item,

        [string]$CategoryTitle,

        [string]$ProductTitle
    )

    $category = ConvertTo-CompactText -Value $CategoryTitle
    $product = ConvertTo-CompactText -Value $ProductTitle
    $productWithoutVolume = ConvertTo-CompactText -Value ([regex]::Replace($ProductTitle, "[（(][^）)]*[）)]", ""))

    $haystack = ConvertTo-CompactText -Value (@(
        [string]$Item.title
        [string]$Item.description
        [string]$Item.pageUrl
        [string]$Item.source
        [string]$Item.link
    ) -join " ")

    $score = 0
    if ($product -and $haystack.Contains($product)) {
        $score += 100
    }
    if ($productWithoutVolume -and $haystack.Contains($productWithoutVolume)) {
        $score += 60
    }
    if ($category -and $haystack.Contains($category)) {
        $score += 30
    }

    $volumeMatch = [regex]::Match($ProductTitle, "(\d+)\s*(ml|ML|公升|L|l)")
    if ($volumeMatch.Success -and $haystack.Contains($volumeMatch.Groups[1].Value)) {
        $score += 15
    }

    return $score
}

function Invoke-BraveImageSearch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    $normalizedApiKey = $ApiKey.Trim().Trim('"', "'")
    $headers = @{
        "Accept" = "application/json"
        "X-Subscription-Token" = $normalizedApiKey
    }

    $queryParts = @(
        "q=$([System.Net.WebUtility]::UrlEncode($Query))"
        "count=$([Math]::Min([Math]::Max($MaxResultsToTry, 1), 200))"
        "country=$([System.Net.WebUtility]::UrlEncode($Country))"
        "search_lang=$([System.Net.WebUtility]::UrlEncode($SearchLang))"
        "safesearch=strict"
        "spellcheck=false"
    )

    $uri = "https://api.search.brave.com/res/v1/images/search?$($queryParts -join '&')"

    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        if ($statusCode -eq 401) {
            throw "Brave rejected the API key. Copy it from https://api-dashboard.search.brave.com/ and pass it with -ApiKey or BRAVE_SEARCH_API_KEY."
        }

        throw
    }

    if ($response.PSObject.Properties.Name -notcontains "results") {
        return @()
    }

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($result in @($response.results)) {
        if ($items.Count -ge $MaxResultsToTry) {
            break
        }

        $imageUrl = $null
        if ($result.PSObject.Properties.Name -contains "properties" -and $result.properties.PSObject.Properties.Name -contains "url") {
            $imageUrl = [string]$result.properties.url
        }
        if ([string]::IsNullOrWhiteSpace($imageUrl) -and $result.PSObject.Properties.Name -contains "thumbnail" -and $result.thumbnail.PSObject.Properties.Name -contains "src") {
            $imageUrl = [string]$result.thumbnail.src
        }

        if ([string]::IsNullOrWhiteSpace($imageUrl)) {
            continue
        }

        $items.Add([pscustomobject]@{
            link = $imageUrl
            title = [string]$result.title
            description = [string]$result.description
            pageUrl = [string]$result.page_url
            source = [string]$result.source
            image = [pscustomobject]@{
                contextLink = [string]$result.page_url
            }
        })
    }

    return $items.ToArray()
}

function Get-ImageExtension {
    param(
        [string]$ImageUrl,
        [string]$ContentType
    )

    if (-not [string]::IsNullOrWhiteSpace($ContentType)) {
        $normalizedType = ($ContentType -split ";")[0].Trim().ToLowerInvariant()
        if ($script:ImageExtensionsByContentType.ContainsKey($normalizedType)) {
            return $script:ImageExtensionsByContentType[$normalizedType]
        }
    }

    try {
        $uri = [System.Uri]$ImageUrl
        $extension = [System.IO.Path]::GetExtension($uri.AbsolutePath).ToLowerInvariant()
        if ($script:AllowedExtensions -contains $extension) {
            if ($extension -eq ".jpeg") {
                return ".jpg"
            }

            return $extension
        }
    }
    catch {
        return ".jpg"
    }

    return ".jpg"
}

function Save-RemoteImage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImageUrl,

        [Parameter(Mandatory = $true)]
        [string]$DestinationBasePath
    )

    $tempPath = [System.IO.Path]::GetTempFileName()
    $webClient = New-Object System.Net.WebClient

    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
        $webClient.DownloadFile($ImageUrl, $tempPath)

        $contentType = $webClient.ResponseHeaders["Content-Type"]
        $extension = Get-ImageExtension -ImageUrl $ImageUrl -ContentType $contentType
        $destinationPath = "$DestinationBasePath$extension"

        if ((Test-Path -LiteralPath $destinationPath) -and -not $Force) {
            return $destinationPath
        }

        $destinationParent = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $destinationParent)) {
            New-Item -ItemType Directory -Path $destinationParent | Out-Null
        }

        Move-Item -LiteralPath $tempPath -Destination $destinationPath -Force:$Force
        $tempPath = $null
        return $destinationPath
    }
    finally {
        $webClient.Dispose()
        if ($tempPath -and (Test-Path -LiteralPath $tempPath)) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

$resolvedSourceFile = Resolve-FullPath -Path $SourceFile
if (-not (Test-Path -LiteralPath $resolvedSourceFile)) {
    throw "Source file does not exist: $resolvedSourceFile"
}

if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    $sourceDirectory = Split-Path -Parent $resolvedSourceFile
    $sourceName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedSourceFile)
    $OutputFile = Join-Path $sourceDirectory "$sourceName.with-images.csv"
}

$ApiKey = $ApiKey.Trim().Trim('"', "'")
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    throw "Brave Search API key is required. Pass -ApiKey or set BRAVE_SEARCH_API_KEY."
}

$resolvedOutputFile = Resolve-FullPath -Path $OutputFile
$resolvedImageRoot = Resolve-FullPath -Path $ImageRoot
if (-not (Test-Path -LiteralPath $resolvedImageRoot)) {
    New-Item -ItemType Directory -Path $resolvedImageRoot | Out-Null
}

$rows = Read-Utf8Csv -Path $resolvedSourceFile
if (-not $rows -or $rows.Count -eq 0) {
    throw "No rows found in source file: $resolvedSourceFile"
}

$report = New-Object System.Collections.Generic.List[object]
$rowNumber = 1
$processedProducts = 0

foreach ($row in $rows) {
    $rowNumber += 1
    $categoryTitle = Get-CellValue -Row $row -ColumnName $CategoryColumn
    $productTitle = Get-CellValue -Row $row -ColumnName $ProductColumn
    $rawImages = Get-CellValue -Row $row -ColumnName $ImagesColumn

    if ([string]::IsNullOrWhiteSpace($productTitle)) {
        $report.Add([pscustomobject]@{
            Row = $rowNumber
            Product = $productTitle
            Status = "Skipped: missing product"
            File = ""
            Url = ""
            Score = ""
            Source = ""
        })
        continue
    }

    if ($MaxProducts -gt 0 -and $processedProducts -ge $MaxProducts) {
        break
    }

    $processedProducts += 1

    if (-not [string]::IsNullOrWhiteSpace($rawImages) -and -not $Force) {
        $report.Add([pscustomobject]@{
            Row = $rowNumber
            Product = $productTitle
            Status = "Skipped: images already set"
            File = $rawImages
            Url = ""
            Score = ""
            Source = ""
        })
        continue
    }

    $slugValue = Get-CellValue -Row $row -ColumnName $ProductSlugColumn
    $productSlug = ConvertTo-Slug -Value $slugValue -Fallback (ConvertTo-Slug -Value $productTitle -Fallback "product-$rowNumber")

    $productWithoutVolume = [regex]::Replace($productTitle, "[（(][^）)]*(?:ml|ML|公升|L|l)[^）)]*[）)]", "").Trim()
    $queryParts = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($categoryTitle)) {
        $queryParts.Add("""$categoryTitle""")
    }
    if (-not [string]::IsNullOrWhiteSpace($productTitle)) {
        $queryParts.Add("""$productTitle""")
    }
    if (-not [string]::IsNullOrWhiteSpace($productWithoutVolume) -and $productWithoutVolume -ne $productTitle) {
        $queryParts.Add("""$productWithoutVolume""")
    }
    if (-not [string]::IsNullOrWhiteSpace($QuerySuffix)) {
        $queryParts.Add($QuerySuffix)
    }
    $query = ($queryParts -join " ").Trim()
    Write-Host "Searching: $query"
    $items = Invoke-BraveImageSearch -Query $query

    if ($items.Count -eq 0) {
        $report.Add([pscustomobject]@{
            Row = $rowNumber
            Product = $productTitle
            Status = "No results"
            File = ""
            Url = ""
            Score = ""
            Source = ""
        })
        continue
    }

    $downloaded = New-Object System.Collections.Generic.List[string]
    $candidateCount = 0

    foreach ($item in $items) {
        if ($downloaded.Count -ge $MaxImagesPerProduct -or ($CandidatesOnly -and $candidateCount -ge $MaxImagesPerProduct)) {
            break
        }

        $imageUrl = [string]$item.link
        if ([string]::IsNullOrWhiteSpace($imageUrl)) {
            continue
        }

        $score = Get-ResultScore -Item $item -CategoryTitle $categoryTitle -ProductTitle $productTitle
        if ($score -lt $MinScore) {
            $report.Add([pscustomobject]@{
                Row = $rowNumber
                Product = $productTitle
                Status = "Rejected: low score"
                File = ""
                Url = $imageUrl
                Score = $score
                Source = [string]$item.image.contextLink
            })
            continue
        }

        $candidateCount += 1
        $relativeBase = Join-Path $productSlug ("$productSlug-$candidateCount")
        $destinationBase = Join-Path $resolvedImageRoot $relativeBase

        if ($CandidatesOnly) {
            $report.Add([pscustomobject]@{
                Row = $rowNumber
                Product = $productTitle
                Status = "Candidate"
                File = ""
                Url = $imageUrl
                Score = $score
                Source = [string]$item.image.contextLink
            })
            continue
        }

        try {
            $savedPath = Save-RemoteImage -ImageUrl $imageUrl -DestinationBasePath $destinationBase
            $relativePath = $savedPath.Substring($resolvedImageRoot.Length).TrimStart('\','/')
            $downloaded.Add($relativePath)
            $report.Add([pscustomobject]@{
                Row = $rowNumber
                Product = $productTitle
                Status = "Downloaded"
                File = $relativePath
                Url = $imageUrl
                Score = $score
                Source = [string]$item.image.contextLink
            })
        }
        catch {
            $report.Add([pscustomobject]@{
                Row = $rowNumber
                Product = $productTitle
                Status = "Download failed: $($_.Exception.Message)"
                File = ""
                Url = $imageUrl
                Score = $score
                Source = [string]$item.image.contextLink
            })
        }
    }

    if ($downloaded.Count -gt 0) {
        $imageProperty = $row.PSObject.Properties | Where-Object { $_.Name -ieq $ImagesColumn } | Select-Object -First 1
        if (-not $imageProperty) {
            throw "Images column '$ImagesColumn' does not exist."
        }

        $imageProperty.Value = ($downloaded -join ";")
    }
}

$outputParent = Split-Path -Parent $resolvedOutputFile
if (-not (Test-Path -LiteralPath $outputParent)) {
    New-Item -ItemType Directory -Path $outputParent | Out-Null
}

$rows | Export-Csv -LiteralPath $resolvedOutputFile -NoTypeInformation -Encoding UTF8

$reportPath = Join-Path $outputParent ([System.IO.Path]::GetFileNameWithoutExtension($resolvedOutputFile) + ".image-report.csv")
$report | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8

Write-Host "Image CSV written: $resolvedOutputFile"
Write-Host "Report written: $reportPath"

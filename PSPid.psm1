# API docs:
# https://api.golemio.cz/pid/docs/openapi/
# https://pid.cz/o-systemu/opendata/

# generate an API token here:
# https://api.golemio.cz/api-keys

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$TOKEN_FILE_PATH = if (Get-Command Get-PSDataPath -ErrorAction Ignore) {
    # this function is from my custom profile (https://github.com/MatejKafka/powershell-profile)
    Get-PSDataPath -NoCreate PidApiToken.txt
} else {
    # user does not have my custom profile with Get-PSDataPath, use a fallback path
    Join-Path $PSScriptRoot "_PidApiToken.txt"
}

function Set-PidToken([Parameter(Mandatory)][string]$Token) {
    $Token = $Token.Trim()
    Set-Content -NoNewline -Path $script:TOKEN_FILE_PATH $Token
}

function Get-AuthHeaders() {
    try {
        return @{
            "X-Access-Token" = (cat -Raw $TOKEN_FILE_PATH).Trim()
        }
    } catch [System.Management.Automation.ItemNotFoundException] {
        $Link = $PSStyle.FormatHyperlink("https://api.golemio.cz/api-keys", "https://api.golemio.cz/api-keys")
        throw "Missing Golemio API token. Please generate a new API key at " + $Link + " and pass it to 'Set-PidToken'."
    }
}

function Invoke-Pid($Path, $QueryParams = @{}) {
    $QueryStrs = $QueryParams.GetEnumerator() | % {
        if ($_.Value -is [array]) {
            # split into multiple params
            foreach ($v in $_.Value) {@{Key = $_.Key; Value = $v}}
        } elseif ($_.Value -is [hashtable]) {
            # Golemio encodes map params as JSON
            @{Key = $_.Key; Value = ConvertTo-Json $_.Value -Depth 99 -Compress}
        } elseif ($_.Value -is [bool]) {
            @{Key = $_.Key; Value = $_.Value ? "true" : "false"}
        } else {
            $_
        }
    } | % {
        # sigh, apparently still no better way to do this
        [uri]::EscapeDataString($_.Key) + "=" + [uri]::EscapeDataString($_.Value)
    }

    $Url = "https://api.golemio.cz$Path"
    if ($QueryStrs) {
        $Url += "?" + ($QueryStrs -join "&")
    }

    try {
        return irm $Url -Headers (Get-AuthHeaders) | Write-Output
    } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
        if ($_.Exception.StatusCode -ne 400) {
            throw # dunno
        }

        $InvalidFields = $_.ErrorDetails.Message | ConvertFrom-Json | % error_info | ConvertFrom-Json -AsHashtable
        $FieldStrs = $InvalidFields.GetEnumerator() | % {
            $_.Key + " (" + $_.Value.msg + ")"
        }
        throw "Invalid query fields for request to '$Url': " + ($FieldStrs -join ", ")
    }
}

function Get-PidDepartureRaw($StopIds, $Limit = $null, $MinutesAfter = $null <# max 4320 (3 days) #>) {
    if ($null -eq $Limit) {$Limit = 100}
    if ($null -eq $MinutesAfter) {$MinutesAfter = 180}

    function invoke($Offset, $Limit, $Total) {
        return Invoke-Pid "/v2/pid/departureboards" @{
            ids = $StopIds
            minutesAfter = $MinutesAfter
            limit = $Limit
            airCondition = $true
            mode = "mixed"
            order = "timetable"
            skip = "canceled"
            offset = $Offset
            total = $Total
        } | % departures
    }

    if ($Limit -le 100) {
        return invoke 0 $Limit $Limit
    }

    # this may miss a connection if the list shifts between requests ¯\_(ツ)_/¯
    for ($Offset = 0; $Offset -lt $Limit; $Offset += 100) {
        $r = invoke $Offset 100 $Limit
        echo $r
        if (@($r).Count -lt 100) {
            break # reached the end of the query
        }
    }
}

function Get-PidDeparture($Stops) {
    $StopIds = Invoke-Pid "/v2/gtfs/stops" @{names = $Stops} | % features | % {$_.properties.stop_id}
    return Get-PidDepartureRaw $StopIds @Args
}

class PidStop {
    [string]$Name
    [double[]]$Coordinates
    [pscustomobject]$Stop
    [pscustomobject]$Time
    [int]$Delay
}

class PidTrip : IComparable {
    [PidStop[]]$Stops
    [pscustomobject]$Route
    [pscustomobject]$Trip

    [string]Format() {
        return Format-PidTrip $this
    }

    [int] CompareTo([object]$O2) {
        if ($O2 -isnot [PidTrip]) {
            return 1
        }

        return [System.Collections.Comparer]::DefaultInvariant.Compare(
            $this.Stops[0].Time.Scheduled, $O2.Stops[0].Time.Scheduled
        )
    }
}

function Get-PidTrip {
    [Alias("pid")]
    param(
            [Parameter(Mandatory)]
            [string[]]
        $From,
            [Parameter(Mandatory)]
            [string[]]
        $To,
        $Limit = $null
    )

    $StopNames = @($From) + @($To)
    $QueriedStops = Invoke-Pid "/v2/gtfs/stops" @{names = $StopNames} | % features

    $FromIds = $QueriedStops | ? {$_.properties.stop_name -in $From} | % {$_.properties.stop_id}
    $StopIds = $QueriedStops.properties.stop_id

    $FoundStopNames = $QueriedStops.properties.stop_name | select -Unique
    if (compare $StopNames $FoundStopNames) {
        throw "Some of the requested stops could not be found. Found stops: $FoundStopNames"
    }

    function New-Stop($Stop) {
        $FullInfo = $QueriedStops | ? {$_.properties.stop_id -eq $Stop.stop.id}

        $Time = $Stop.departure_timestamp | ? scheduled -ne $null
        if (-not $Time) {
            $Time = $Stop.arrival_timestamp | ? scheduled -ne $null
        }

        return [PidStop]@{
            Name = $FullInfo.properties.stop_name
            Coordinates = $FullInfo.geometry.coordinates
            Stop = $Stop.stop
            Time = $Time
            Delay = if ($Stop.delay.is_available) {$Stop.delay.seconds}
        }
    }

    # find trips containing stops we are interested in
    $Trips = @{}
    Get-PidDepartureRaw $StopIds -Limit $Limit | % {
        if (-not $Trips[$_.trip.id]) {
            $Trips[$_.trip.id] = @()
        }
        $Trips[$_.trip.id] += @($_)
    }

    # find trips that have the stops in the correct order
    $Out = $Trips.GetEnumerator() | % {
        $Stops = @($_.Value `
            | sort {$_.departure_timestamp.scheduled ?? $_.arrival_timestamp.scheduled} `
            | % {@{IsFrom = $_.stop.id -in $FromIds; Stop = $_}})
        # remove To stops at the start
        while ($Stops -and -not $Stops[0].IsFrom) {$Stops = @($Stops | select -Skip 1)}
        # remove From stops at the end
        while ($Stops -and $Stops[-1].IsFrom) {$Stops = @($Stops | select -SkipLast 1)}

        if (-not $Stops) {
            # there were only from/to stops, or the connection was the wrong direction
            return
        }

        $s = $Stops[0].Stop
        [PidTrip]@{
            Stops = $Stops | % {New-Stop $_.Stop}
            Route = $s.route
            Trip = $s.trip
        }
    }

    return $Out | sort
}


function color($Color, $Text) {
    return ($PSStyle.Foreground | % $Color) + $Text  + $PSStyle.Reset
}

function Format-PidStop([Parameter(ValueFromPipeline)][PidStop]$Stop) {
    process {
        $CoordStr = [uri]::EscapeDataString($Stop.Coordinates -join ",")
        $MapUrl = "https://mapy.cz/fnc/v1/showmap?center=$CoordStr&zoom=18&marker=true"
        $Time = $Stop.Time.scheduled.ToString("HH:mm")
        return $Time + " " + $PSStyle.FormatHyperlink((color BrightBlack $Stop.Name), $MapUrl) + " " + (color BrightGreen $Stop.Stop.platform_code)
    }
}

$VehicleTypeMap = @{
    "0"  = "🚋", "Red" # tram
    "1"  = "🚇", "Green" # metro
    "3"  = "🚌", "Blue" # bus
    "11" = "🚎", "Blue" # trolleybus
}

function Format-PidRoute($Route) {
    $t = [string]$Route.type
    if ($VehicleTypeMap.ContainsKey($t)) {
        $Icon, $Color = $VehicleTypeMap[$t]
        return $Icon + (color $Color $Route.short_name.PadRight(3))
    } else {
        return $t + " " + $Route.short_name
    }
}

function Format-PidTrip([Parameter(ValueFromPipeline)][PidTrip]$Trip, [switch]$AllStops) {
    process {
        $Stops = if ($AllStops) {$Trip.Stops} else {$Trip.Stops[0], $Trip.Stops[-1]}
        $s = (Format-PidRoute $Trip.route) + " " + (($Stops | Format-PidStop) -join (color BrightBlack " -> "))

        $d = $Trip.Stops[0].Delay
        if ($d) {
            $s += " ($($d -gt 0 ? "+$d" : "$d") s)"
        }
 
        return $s
    }
}
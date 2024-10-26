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

function Get-AuthHeaders() {
    return @{
        "X-Access-Token" = (cat -Raw $TOKEN_FILE_PATH).Trim()
    }
}

function Invoke-Pid {
    [Alias("pid")]
    param($Path, $QueryParams = @{})

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

function Get-PidDeparture($StopIds, $Limit = 30, $MinutesAfter = 360) {
    return pid "/v2/public/departureboards" @{stopIds = @{"0" = @($StopIds)}; limit = $Limit; minutesAfter = $MinutesAfter} | Write-Output
}

class PidStop {
    [string]$Name
    [double[]]$Coordinates
    [pscustomobject]$Stop
    [pscustomobject]$Departure
}

class PidTrip : IComparable {
    [PidStop[]]$Stops
    [pscustomobject]$Route
    [pscustomobject]$Trip
    [pscustomobject]$Vehicle

    [string]Format() {
        return Format-PidTrip $this
    }

    [int] CompareTo([object]$O2) {
        if ($O2 -isnot [PidTrip]) {
            return 1
        }

        return [System.Collections.Comparer]::DefaultInvariant.Compare(
            [tuple]::Create($this.Stops[0].departure.timestamp_scheduled, $this.Stops[1].departure.timestamp_scheduled),
            [tuple]::Create($O2.Stops[0].departure.timestamp_scheduled, $O2.Stops[1].departure.timestamp_scheduled)
        )
    }
}

function Get-PidTrip([Parameter(Mandatory)][string[]]$From, [Parameter(Mandatory)][string[]]$To) {
    $StopNames = @($From) + @($To)
    $QueriedStops = pid "/v2/gtfs/stops" @{names = $StopNames} | % features
    $StopsFrom = $QueriedStops | ? {$_.properties.stop_name -in $From}
    $StopsTo = $QueriedStops | ? {$_.properties.stop_name -in $To}

    $FoundStopNames = $QueriedStops.properties.stop_name | select -Unique
    if (compare $StopNames $FoundStopNames) {
        throw "Some of the requested stops could not be found. Found stops: $FoundStopNames"
    }

    $FromIds = $StopsFrom.properties.stop_id
    $ToIds = $StopsTo.properties.stop_id

    function New-Stop($Stop) {
        $FullInfo = $QueriedStops | ? {$_.properties.stop_id -eq $Stop.stop.id}
        return [PidStop]@{
            Name = $FullInfo.properties.stop_name
            Coordinates = $FullInfo.geometry.coordinates
            Stop = $Stop.stop
            Departure = $Stop.Departure
        }
    }

    $Trips = @{}
    # departures have pretty low pagination limit, retrieve one by one
    (@($FromIds) + @($ToIds)) | % {Get-PidDeparture $_} | % {
        if (-not $Trips[$_.trip.id]) {
            $Trips[$_.trip.id] = @()
        }
        $Trips[$_.trip.id] += @($_)
    }

    $Out = $Trips.GetEnumerator() | % {
        $Stops = @($_.Value | sort {$_.stop.sequence} | % {@{IsFrom = $_.stop.id -in $FromIds; Stop = $_}})
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
            Vehicle = $s.vehicle
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
        $Time = $Stop.departure.timestamp_scheduled.ToString("HH:mm")
        return $Time + " " + $PSStyle.FormatHyperlink((color BrightBlack $Stop.Name), $MapUrl) + " " + (color BrightGreen $Stop.Stop.platform_code)
    }
}

$VehicleTypeMap = @{
    "tram" = "🚋", "Red"
    "bus" = "🚌", "Blue"
    "metro" = "🚇", "Green"
}

function Format-PidRoute($Route) {
    if ($VehicleTypeMap.ContainsKey($Route.type)) {
        $Icon, $Color = $VehicleTypeMap[$Route.type]
        return $Icon + (color $Color $Route.short_name)
    } else {
        return $Route.type + " " + $Route.short_name
    }
}

function Format-PidTrip([Parameter(ValueFromPipeline)][PidTrip]$Trip, [switch]$AllStops) {
    process {
        $Stops = if ($AllStops) {$Trip.Stops} else {$Trip.Stops[0], $Trip.Stops[-1]}
        $s = (Format-PidRoute $Trip.route) + " " + (($Stops | Format-PidStop) -join (color BrightBlack " -> "))
        if ($Trip.Stops[0].departure.delay_seconds) {
            $s += " (+$($Trip.Stops[0].departure.delay_seconds) s)"
        }
 
        return $s
    }
}
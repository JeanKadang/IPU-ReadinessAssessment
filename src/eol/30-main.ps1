# Dot-sourcing (tests) loads the functions only.
if ($MyInvocation.InvocationName -ne '.') {
    if ($Update) {
        if (-not $SnapshotPath) { throw 'Give -SnapshotPath: the file to write the snapshot to.' }
        $saved = Save-EolSnapshot -Path $SnapshotPath -Today (Get-Date)
        $saved | Add-Member -NotePropertyName Attribution -NotePropertyValue $script:EolAttribution -PassThru
        return
    }
    if (-not $Product -or -not $Version) { throw ('Give -Product and -Version, or -Update with -SnapshotPath to create the snapshot. See: Get-Help "' + $PSCommandPath + '" -Full') }
    if (-not $script:EolProducts.Contains($Product)) { throw ('Unsupported product ' + $Product + '. Supported: ' + ($script:EolProducts.Keys -join ', ')) }
    $data = Get-EolSnapshotRelease -Product $Product -SnapshotPath $SnapshotPath
    if ($null -eq $data -and $Online) { $data = Get-EolOnlineRelease -Product $Product }
    if ($null -eq $data) {
        # No data is MANUAL, never a clean result.
        [pscustomobject][ordered]@{ Product = $Product; Version = $Version; Cycle = ''; State = 'Unknown'; Status = 'MANUAL'; EolDate = ''; DaysLeft = $null
            Text = 'No lifecycle data for ' + $Product + ' in the snapshot. Update the snapshot or use -Online.'; Source = ''; AsOf = ''; Attribution = $script:EolAttribution }
        return
    }
    $d = Get-EolDecision -Product $Product -Version $Version -Cycles $data.Cycles -Today (Get-Date) -WarnDays $WarnDays
    $d = ConvertTo-EolStaleDecision $d (Get-EolSnapshotAge -AsOf $data.AsOf -Today (Get-Date) -MaxAgeMonths $MaxAgeMonths)
    $d | Add-Member -NotePropertyName Source -NotePropertyValue $data.Source -PassThru |
        Add-Member -NotePropertyName AsOf -NotePropertyValue $data.AsOf -PassThru |
        Add-Member -NotePropertyName Attribution -NotePropertyValue $script:EolAttribution -PassThru
}

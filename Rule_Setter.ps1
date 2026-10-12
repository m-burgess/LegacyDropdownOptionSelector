Add-Type -AssemblyName System.Windows.Forms

if (-not ("KeyboardState" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class KeyboardState
{
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
}
"@
}

# ============================================================
# QUERY ROW RULE SENDER
#
# NO CLIPBOARD ACCESS
#
# Paste the entire tab-delimited query result row directly
# into the PowerShell window.
#
# DO NOT press Enter after pasting.
#
# The script reads the pasted characters from the console
# input buffer and automatically detects when the paste ends.
#
# Expected columns:
#
#  0  Row_ID
#  1  FormSetName
#  2  DisplayName
#  3  FormName
#  4  FormDescription
#  5  FieldTag
#  6  FieldDescription
#  7  SortOrder
#  8  Rule Type
#  9  RuleName
# 10  RuleExpression
# 11  Rule Category
# 12  Rule Sub-Category
#
# IMPORTANT:
#
# If RuleName exists:
#     RuleExpression is completely ignored while pasting.
#
# If RuleName is blank:
#     RuleExpression is captured ONLY if it does NOT
#     contain "xml".
#
# XML expressions are discarded while they are being read.
#
# SHIFT #1 = Rule Category
# SHIFT #2 = Rule Sub-Category
# SHIFT #3 = RuleName or non-XML RuleExpression
#
# Missing values are skipped automatically.
#
# Every value sent is automatically followed by ENTER.
# ============================================================


# ============================================================
# SETTINGS
# ============================================================

$VK_SHIFT = 0x10

$pollMilliseconds = 10

# Paste is considered finished after this amount of time
# with no additional console characters.
$pasteCompleteDelay = 500

# Delay after SHIFT is released before SendKeys fires.
$sendDelayMilliseconds = 100


# ============================================================
# CLEAN VALUE
# ============================================================

function Get-CleanQueryValue {

    param(
        [string]$Value
    )

    if ($null -eq $Value) {
        return ""
    }

    $Value = $Value.Trim()

    if (
        $Value -eq "" -or
        $Value -match '^(?i:NULL)$' -or
        $Value -match '^(?i:\(NULL\))$'
    ) {
        return ""
    }

    return $Value
}


# ============================================================
# SENDKEYS ESCAPING
# ============================================================

function Convert-ToSendKeysLiteral {

    param(
        [string]$Text
    )

    if ($null -eq $Text) {
        return ""
    }

    $Text = $Text.Replace("{", "{{}")
    $Text = $Text.Replace("}", "{}}")
    $Text = $Text.Replace("+", "{+}")
    $Text = $Text.Replace("^", "{^}")
    $Text = $Text.Replace("%", "{%}")
    $Text = $Text.Replace("~", "{~}")
    $Text = $Text.Replace("(", "{(}")
    $Text = $Text.Replace(")", "{)}")

    return $Text
}


# ============================================================
# WAIT FOR SHIFT
# ============================================================

function Wait-ForShift {

    # Make sure SHIFT is released before waiting.
    while (
        ([KeyboardState]::GetAsyncKeyState($VK_SHIFT) -band 0x8000) -ne 0
    ) {
        Start-Sleep -Milliseconds 10
    }


    # Wait for SHIFT press.
    while (
        ([KeyboardState]::GetAsyncKeyState($VK_SHIFT) -band 0x8000) -eq 0
    ) {
        Start-Sleep -Milliseconds $pollMilliseconds
    }


    # Wait for SHIFT release.
    while (
        ([KeyboardState]::GetAsyncKeyState($VK_SHIFT) -band 0x8000) -ne 0
    ) {
        Start-Sleep -Milliseconds 10
    }


    Start-Sleep -Milliseconds $sendDelayMilliseconds
}


# ============================================================
# SEND VALUE + ENTER
# ============================================================

function Send-DpfValue {

    param(
        [string]$Value
    )

    $sendText = Convert-ToSendKeysLiteral -Text $Value

    if ($sendText -ne "") {

        [System.Windows.Forms.SendKeys]::SendWait(
            $sendText
        )
    }

    [System.Windows.Forms.SendKeys]::SendWait(
        "{ENTER}"
    )
}


# ============================================================
# READ QUERY ROW DIRECTLY FROM CONSOLE INPUT
#
# NO WINDOWS CLIPBOARD ACCESS IS USED.
#
# This parser processes the paste as it arrives.
#
# For column 10 (RuleExpression):
#
# - If RuleName exists, the expression is discarded.
# - If "xml" is detected, the expression is discarded.
# - Otherwise it is retained in case there is no RuleName.
# ============================================================

function Read-And-ParseQueryRow {

    Write-Host ""
    Write-Host "============================================================"
    Write-Host " PASTE QUERY RESULT ROW"
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "Paste the entire query result row now."
    Write-Host ""
    Write-Host "DO NOT press Enter."
    Write-Host ""
    Write-Host "Waiting for paste..."
    Write-Host ""


    $fields = New-Object System.Collections.ArrayList

    $currentField = New-Object System.Text.StringBuilder

    $columnIndex = 0

    $started = $false

    $lastInput = [DateTime]::Now


    # --------------------------------------------------------
    # RULE NAME STATUS
    #
    # Once column 9 has been completed we know whether the
    # expression needs to be considered at all.
    # --------------------------------------------------------

    $knownRuleName = ""

    $ignoreExpression = $false

    $expressionContainsXml = $false


    while ($true) {


        # ====================================================
        # DRAIN ALL CURRENTLY AVAILABLE CONSOLE CHARACTERS
        #
        # There is intentionally no sleep inside this inner
        # loop so large pasted rows are consumed quickly.
        # ====================================================

        while ([Console]::KeyAvailable) {

            $key = [Console]::ReadKey($true)

            $started = $true

            $lastInput = [DateTime]::Now


            $character = $key.KeyChar


            # =================================================
            # TAB = NEXT QUERY COLUMN
            # =================================================

            if ([int]$character -eq 9) {


                # ------------------------------------------------
                # COMPLETE CURRENT FIELD
                # ------------------------------------------------

                if ($columnIndex -eq 10) {

                    # RuleExpression column.

                    if (
                        $ignoreExpression -or
                        $expressionContainsXml
                    ) {

                        [void]$fields.Add("")

                    }
                    else {

                        [void]$fields.Add(
                            $currentField.ToString()
                        )
                    }

                }
                else {

                    [void]$fields.Add(
                        $currentField.ToString()
                    )
                }


                # ------------------------------------------------
                # COLUMN 9 JUST FINISHED = RULE NAME
                # ------------------------------------------------

                if ($columnIndex -eq 9) {

                    $knownRuleName = Get-CleanQueryValue (
                        $currentField.ToString()
                    )

                    if ($knownRuleName -ne "") {

                        # RuleName exists.
                        # Completely discard RuleExpression.
                        $ignoreExpression = $true
                    }
                    else {

                        $ignoreExpression = $false
                    }
                }


                # ------------------------------------------------
                # MOVE TO NEXT COLUMN
                # ------------------------------------------------

                $columnIndex++

                $currentField.Clear() | Out-Null

                continue
            }


            # =================================================
            # CR / LF
            #
            # Ignore carriage returns and linefeeds.
            #
            # Query rows in this workflow are expected to be
            # one logical row.
            # =================================================

            if (
                [int]$character -eq 10 -or
                [int]$character -eq 13
            ) {

                continue
            }


            # =================================================
            # RULE EXPRESSION COLUMN
            # =================================================

            if ($columnIndex -eq 10) {


                # ------------------------------------------------
                # RULE NAME EXISTS
                #
                # Discard the entire expression immediately.
                # ------------------------------------------------

                if ($ignoreExpression) {

                    continue
                }


                # ------------------------------------------------
                # XML ALREADY FOUND
                #
                # Continue discarding expression characters.
                # ------------------------------------------------

                if ($expressionContainsXml) {

                    continue
                }


                # ------------------------------------------------
                # ADD CHARACTER TEMPORARILY
                # ------------------------------------------------

                [void]$currentField.Append($character)


                # ------------------------------------------------
                # DETECT XML AS SOON AS POSSIBLE
                #
                # Typical value begins:
                #
                # ~<?xml
                #
                # As soon as "xml" appears, dump the expression
                # buffer and ignore the remainder of column 10.
                # ------------------------------------------------

                if (
                    $currentField.Length -ge 3 -and
                    $currentField.ToString() -match '(?i)xml'
                ) {

                    $expressionContainsXml = $true

                    $currentField.Clear() | Out-Null
                }


                continue
            }


            # =================================================
            # NORMAL QUERY COLUMN
            # =================================================

            if ([int]$character -ne 0) {

                [void]$currentField.Append(
                    $character
                )
            }
        }


        # ====================================================
        # DETECT END OF PASTE
        # ====================================================

        if ($started) {

            $elapsed = (
                [DateTime]::Now - $lastInput
            ).TotalMilliseconds


            if ($elapsed -ge $pasteCompleteDelay) {

                break
            }
        }


        Start-Sleep -Milliseconds $pollMilliseconds
    }


    # ========================================================
    # ADD FINAL COLUMN
    # ========================================================

    [void]$fields.Add(
        $currentField.ToString()
    )


    # ========================================================
    # VALIDATE QUERY COLUMN COUNT
    # ========================================================

    if ($fields.Count -lt 13) {

        Write-Host ""
        Write-Host "ERROR:"
        Write-Host ""
        Write-Host "Expected at least 13 tab-delimited columns."
        Write-Host "Detected: $($fields.Count)"
        Write-Host ""

        return $null
    }


    # ========================================================
    # EXTRACT STANDARD VALUES
    # ========================================================

    $fieldTag = Get-CleanQueryValue $fields[5]

    $fieldDescription = Get-CleanQueryValue $fields[6]

    $sortOrder = Get-CleanQueryValue $fields[7]

    $ruleType = Get-CleanQueryValue $fields[8]

    $ruleName = Get-CleanQueryValue $fields[9]


    # ========================================================
    # RULE CATEGORY / SUB-CATEGORY
    # ========================================================

    $ruleCategory = Get-CleanQueryValue $fields[11]

    $ruleSubCategory = Get-CleanQueryValue $fields[12]


    # ========================================================
    # RULE VALUE
    # ========================================================

    $ruleValue = ""

    $usingExpression = $false


    if ($ruleName -ne "") {

        # ----------------------------------------------------
        # RULE NAME EXISTS
        #
        # Expression was completely ignored.
        # ----------------------------------------------------

        $ruleValue = $ruleName

        $usingExpression = $false

    }
    else {

        # ----------------------------------------------------
        # NO RULE NAME
        # ----------------------------------------------------

        $usingExpression = $true


        if ($expressionContainsXml) {

            $ruleValue = ""

        }
        else {

            $ruleValue = Get-CleanQueryValue $fields[10]
        }
    }


    return [PSCustomObject]@{

        FieldTag = $fieldTag

        FieldDescription = $fieldDescription

        SortOrder = $sortOrder

        RuleType = $ruleType

        RuleCategory = $ruleCategory

        RuleSubCategory = $ruleSubCategory

        RuleName = $ruleName

        RuleValue = $ruleValue

        UsingExpression = $usingExpression

        XmlExpressionIgnored = $expressionContainsXml
    }
}


# ============================================================
# PROCESS QUERY ROW
# ============================================================

function Process-QueryRow {

    param(
        $ParsedRow
    )


    Clear-Host

    Write-Host "============================================================"
    Write-Host " QUERY ROW RULE SENDER"
    Write-Host "============================================================"
    Write-Host ""

    Write-Host "FIELD:"
    Write-Host "  $($ParsedRow.FieldTag)"
    Write-Host ""

    Write-Host "DESCRIPTION:"
    Write-Host "  $($ParsedRow.FieldDescription)"
    Write-Host ""

    Write-Host "SORT ORDER:"
    Write-Host "  $($ParsedRow.SortOrder)"
    Write-Host ""

    Write-Host "RULE TYPE:"
    Write-Host "  $($ParsedRow.RuleType)"
    Write-Host ""

    Write-Host "RULE CATEGORY:"
    Write-Host "  $($ParsedRow.RuleCategory)"
    Write-Host ""

    Write-Host "RULE SUB-CATEGORY:"
    Write-Host "  $($ParsedRow.RuleSubCategory)"
    Write-Host ""


    # ========================================================
    # RULE STATUS
    # ========================================================

    if ($ParsedRow.RuleName -ne "") {

        Write-Host "RULE NAME:"
        Write-Host "  $($ParsedRow.RuleName)"
        Write-Host ""
        Write-Host "RuleExpression ignored."
        Write-Host ""

    }
    elseif ($ParsedRow.XmlExpressionIgnored) {

        Write-Host "============================================================"
        Write-Host " NO RULE NAME"
        Write-Host "============================================================"
        Write-Host ""
        Write-Host "RuleExpression contained XML."
        Write-Host ""
        Write-Host "XML expression ignored."
        Write-Host ""

    }
    elseif ($ParsedRow.RuleValue -ne "") {

        Write-Host "============================================================"
        Write-Host " NO RULE NAME"
        Write-Host "============================================================"
        Write-Host ""
        Write-Host "Using RuleExpression:"
        Write-Host ""
        Write-Host "  $($ParsedRow.RuleValue)"
        Write-Host ""
    }


    # ========================================================
    # BUILD SHIFT QUEUE
    # ========================================================

    $sendQueue = @()


    # --------------------------------------------------------
    # SHIFT #1 - RULE CATEGORY
    #
    # Example:
    #
    # Product Name
    # --------------------------------------------------------

    if ($ParsedRow.RuleCategory -ne "") {

        $sendQueue += [PSCustomObject]@{
            Label = "RULE CATEGORY"
            Value = $ParsedRow.RuleCategory
        }
    }


    # --------------------------------------------------------
    # SHIFT #2 - RULE SUB-CATEGORY
    #
    # Example:
    #
    # Field Include Rules
    # --------------------------------------------------------

    if ($ParsedRow.RuleSubCategory -ne "") {

        $sendQueue += [PSCustomObject]@{
            Label = "SUB-CATEGORY"
            Value = $ParsedRow.RuleSubCategory
        }
    }


    # --------------------------------------------------------
    # SHIFT #3 - RULE NAME / EXPRESSION
    #
    # Example:
    #
    # HasRejectExcessUIMCovLimit
    # --------------------------------------------------------

    if ($ParsedRow.RuleValue -ne "") {

        if ($ParsedRow.UsingExpression) {

            $sendQueue += [PSCustomObject]@{
                Label = "RULE EXPRESSION"
                Value = $ParsedRow.RuleValue
            }

        }
        else {

            $sendQueue += [PSCustomObject]@{
                Label = "RULE NAME"
                Value = $ParsedRow.RuleValue
            }
        }
    }


    # ========================================================
    # NOTHING TO SEND
    # ========================================================

    if ($sendQueue.Count -eq 0) {

        Write-Host "No usable rule values found."
        Write-Host ""

        Start-Sleep -Milliseconds 750

        return
    }


    # ========================================================
    # PROCESS SHIFT QUEUE
    # ========================================================

    for (
        $queueIndex = 0;
        $queueIndex -lt $sendQueue.Count;
        $queueIndex++
    ) {

        $item = $sendQueue[$queueIndex]


        Write-Host "------------------------------------------------------------"
        Write-Host ""
        Write-Host "STEP $($queueIndex + 1) OF $($sendQueue.Count)"
        Write-Host ""
        Write-Host "$($item.Label):"
        Write-Host ""
        Write-Host "  $($item.Value)"
        Write-Host ""
        Write-Host "Focus the correct DPF selection control."
        Write-Host ""
        Write-Host "PRESS SHIFT TO SEND"
        Write-Host ""


        Wait-ForShift


        Send-DpfValue -Value $item.Value


        Write-Host "SENT:"
        Write-Host "  $($item.Value)"
        Write-Host ""
    }


    Write-Host "============================================================"
    Write-Host " ROW COMPLETE"
    Write-Host "============================================================"
    Write-Host ""

    Start-Sleep -Milliseconds 300
}


# ============================================================
# MAIN LOOP
# ============================================================

Clear-Host

Write-Host "============================================================"
Write-Host "QUERY ROW RULE SENDER"
Write-Host "============================================================"
Write-Host ""
Write-Host "Paste an entire query result row."
Write-Host ""
Write-Host "DO NOT press Enter."
Write-Host ""
Write-Host "NO clipboard reading is used."
Write-Host ""
Write-Host "If RuleName exists:"
Write-Host "  RuleExpression is ignored completely."
Write-Host ""
Write-Host "If RuleName is blank:"
Write-Host "  Non-XML expressions can be used."
Write-Host "  XML expressions are discarded."
Write-Host ""
Write-Host "SHIFT triggers each extracted value."
Write-Host ""


while ($true) {

    $parsedRow = Read-And-ParseQueryRow


    if ($null -eq $parsedRow) {

        Start-Sleep -Milliseconds 500

        continue
    }


    Process-QueryRow -ParsedRow $parsedRow
}

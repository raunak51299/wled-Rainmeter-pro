Option Explicit

Dim shell, args, command, index
Set shell = CreateObject("WScript.Shell")
Set args = WScript.Arguments

If args.Count = 0 Then WScript.Quit 2

command = QuoteArgument(shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"))
command = command & " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File"

For index = 0 To args.Count - 1
    command = command & " " & QuoteArgument(args(index))
Next

shell.Run command, 0, False

Function QuoteArgument(value)
    QuoteArgument = """" & Replace(value, """", """""") & """"
End Function

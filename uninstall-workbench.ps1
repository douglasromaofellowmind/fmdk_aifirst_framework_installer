#Requires -Version 5.1
<#
.SYNOPSIS
    FMDK Agentic OS uninstaller - stops the app and removes the installation.
.DESCRIPTION
    Removes what install-workbench.ps1 put on this PC: the app and Framework
    CLI clones under %LOCALAPPDATA%\FMDK-Workbench, the Desktop and Start Menu
    shortcuts, and the CLAUDE_DIR / FMDK_CLI_PATH / NUXT_* variables. Your
    workbench home (%USERPROFILE%\FMDK-Workbench - portfolio, projects, assets)
    is only deleted if you tick the box for it. Node.js, Git, the GitHub CLI,
    the Azure CLI, the Claude CLI and your sign-ins are left alone: they are
    shared with everything else on the PC. Asks first, in a window styled like
    the installer; in the console if the window cannot open.
#>

$ErrorActionPreference = 'Stop'

$InstallRoot = Join-Path $env:LOCALAPPDATA 'FMDK-Workbench'
$WorkbenchHome = Join-Path $env:USERPROFILE 'FMDK-Workbench'
$StartMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'FMDK Agentic OS'
$DesktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'FMDK Agentic OS.lnk'
$EnvVars = @('CLAUDE_DIR', 'FMDK_CLI_PATH', 'NUXT_FMDK_CLI_PATH', 'NUXT_CLAUDE_CLI_PATH')

# ---- the removals (each is one row; each is safe to run when there is nothing to do) ----

function Stop-App {
    $stopped = 0
    $conn = Get-NetTCPConnection -LocalPort 3030 -State Listen -ErrorAction SilentlyContinue
    foreach ($c in @($conn)) {
        try { Stop-Process -Id $c.OwningProcess -Force -ErrorAction Stop; $stopped++ } catch { }
    }
    # The hidden launcher's node.exe may have moved off the port; anything started from the app folder goes too.
    $appDir = (Join-Path $InstallRoot 'app').ToLowerInvariant()
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue)) {
        if ($p.CommandLine -and $p.CommandLine.ToLowerInvariant().Contains($appDir)) {
            try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $stopped++ } catch { }
        }
    }
    if ($stopped) { Start-Sleep -Milliseconds 800 }   # let file handles go before the folder is removed
    return "$stopped process(es) stopped"
}

function Remove-Shortcuts {
    $n = 0
    if (Test-Path $DesktopShortcut) { Remove-Item -Force $DesktopShortcut; $n++ }
    if (Test-Path $StartMenuDir) { Remove-Item -Recurse -Force $StartMenuDir; $n++ }
    return $(if ($n) { "removed" } else { "nothing to remove" })
}

function Remove-Settings {
    $n = 0
    foreach ($name in $EnvVars) {
        if ([Environment]::GetEnvironmentVariable($name, 'User') -ne $null) {
            [Environment]::SetEnvironmentVariable($name, $null, 'User')
            $n++
        }
    }
    return "$n variable(s) removed"
}

function Remove-Folder {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return 'nothing to remove' }
    # This script lives inside $InstallRoot: PowerShell has already read it, but
    # the console must not be sitting in the folder it is about to delete.
    Set-Location $env:USERPROFILE
    try {
        Remove-Item -Recurse -Force $Path -ErrorAction Stop
    } catch {
        Start-Sleep -Seconds 1   # a handle the stopped app was still releasing
        Remove-Item -Recurse -Force $Path -ErrorAction Stop
    }
    return 'removed'
}

# ---- the window ----

# The Hive AI mark (ui-react/public/brand/hive-ai-mark.png at 128px), embedded
# because this script may be the last thing left on the machine. Same bytes as
# install-workbench.ps1 carries; scripts/installer-window.test.mjs pins that.
$HiveMarkPng = @'
iVBORw0KGgoAAAANSUhEUgAAAHEAAACACAYAAAA8sIZsAAAAAXNSR0IArs4c6QAAAHhlWElmTU0AKgAAAAgABAEaAAUAAAABAAAAPgEbAAUAAAABAAAARgEoAAMAAAABAAIAAIdpAAQAAAABAAAATgAAAAAAAADYAAAAAQAAANgAAAABAAOgAQADAAAAAQABAACgAgAEAAAAAQAAAHGgAwAEAAAAAQAAAIAAAAAAnJz2fAAAAAlwSFlzAAAhOAAAITgBRZYxYAAAQABJREFUeAHdnXuwZVdd5/fe53Fvdzqd7iSd7jw6D/IkPYRH4mBUNGgcZEoFpBK0HLSGQYxYcXDwMdb8MdRUTaljGcQRShiVwhellAgyxjLDDCpDMmAQAfMmCQl5kmcn6XTfe17z/Xx/v7XPPvd2x3TSCR1W33PWWr/X+q3fd/3W2nufc2/X1TdZmVVVveeSU7ePVpZe3NSzc6umOkb1/aNJff1gdXrjpr/6yoN1VUnsm6doPt8c5drzzx+cedJjr6jq5sfr2ey1TV2f1KurfpUznFTVaDqd3TGrZn/Znw4+9JdL13/p0o9UIr/wyzcFiI+94Zyzqsn0bb1+/cPNrDpxrDybzgQX+OQMa9Ug2qgW/Y7RrPrD2WzywS0f+8qtL3QYX9AgPvGDp22fzJYurXvTy5qqOXcqeCYCr4NdC2IXqL6QrKuZErP6slTe9/ik+ugJn7j5wa7MC6n9ggRxdsmu4aMrk+/Xdnl5v64unFbV0ijBK8fduomtIdAFzKaa7Z1U9d9OxtPfuuXuW6664PPV6IUEIL6umdrh7f67qqr5968/5+TepPnJfq+6TBvmltFM+RfJ15nNbP3EDjBTtte+9lpVD41ns99cGVW/e8z/vPke9YvVwzsoLyQQd79m19GTpembBrPqp5um3qWAV2yfUbJeAOrpA4mNnoBUVutKZ/aFata8ZzTb9/GtH/vqoznAYV0tTPtw9HT2AydsfHB69KsHvek7m2l1Ua3LTrKPUtdPBSKJWfg5s6cx26H26Nl0NtFl61XNrP/rjwweu3rnR+7amxYOy+ppTOsb4/dMtwwP7thz3rAaXF431Rt7zWzT6iRzz14r07Je2PkWZnRw2VhmignAnMyq3VonH15Zbd67dc8NN9Z/U42LzOFUL0z5cHBMuVPf+wO7di5N+j8xaGZv0Xl1wsp0XM1aT8vWiWTJtk7GtXIxm2eSjSUObLGDpqrGk+md9az3/id7ez+47aN33Fv4h0u9ZsrfWLfu+I6XbD3qqP4P6bD7mV4zPY878QlbZ83LP+kgAAZwTycbUVqY6EInTT5FNdAgqMxms2vHVf2eyROjTxz9ydt2P4XK88o6yOk8N77dc/75G5e2zV41a2Y/15/Vr27qaW/Vl5xsmZllAjIAw4c5iE8nG8t22062bRzEfDTkUJeyuiJe1YF51Up/csWxD0+uqf/mq/sOwspzIvpMpnPIHOFR2c7N03P7g8HlOvMuaZrp5lXdgXONWFInQAS0bjYiA02VXvMtE3rQolHek95lPZOZy4x2V4Opp0KPKDP/uBrP3rtp4y0319/AR3jPZColMs+mrh/87gtPmPQnbx3W9Vt7VXXSKhf3mWEBSoAGWO2WqcvTucOAyMs/8gWgeKnMhaJf6NmzyDqZDvOpmjlET4PoXpXHe7fpKdH7907HH9r+F7ff/1SqzxXvmU7lGftz+0Uv23Jks/H1VU/nXjV7+VQZ5kdlbJcEWw8/A0S123OPyNFfk40tH3dShua6WcFbW3TOPS25tXrqd8xxXjLerJ59djyp3n3UrL6y/oubHt+P1nNGWjeN52qkr1144YZmY/Mdg1n9s7p6/15tk/2RP0RI0JxVmWktkGuysSuDo4DqmjiWyKpeN6vCC3EE1gNYeNRr5QsPw+t5UAfcX85mq9NpfeWoP7ti657p5+q/+spK0Xwu63XTPdSDvUu5ddm3fdu59fLwp3uz6Y/0mvqo1ZluGfSvFljakDykzz6BVNNvQRS/zTZks2851Eq/4FZkbLLzBr2Ufw7AIke9qBecLq0rK7cVTS5+xtP6Yc3kDzTH9x355zfeIvKBlRZNPKPecwriQ6987ebVpdU395vZz+ue65SRwON2va7zwgUwDBJXnsxTL7ZVedXtM7N5HxnAzrJ2izUZmSJAjW3KwQAYGuvfi631nKDUeoSnzGwa5nrLeNr8yu17HvqTl151/54DaTxb+sJUn62xon/LGa9d2nT86OKmbn5RV3Ovmgo03+/lhUntbTC2ylq0tdlIX09pFHICBiCL2Wqgy2AtD0IJMDpFoNAPBYDFZhmn9EvdGdRA4pFpn9Ty/dWjmsHf1R+5brVIH6q6M+qzN/mpiy7q71rZ8JJRr/oFfQD7Bt0yLK3OuGXPTHPWMC0yEBAJhtq5rcY5BQD6cEiezbMvQIwMhI9+CWT0idVTnYtPfQYe7NzL2F29Tii7TbWXeIQ3rfdO6urD41717q3TG244lLckneG6Dh1cmzDe/crXnlg1vbfXdf22ob7XsjobCZ4IcNk+47wToDbfAdKgAHYCR1/Ac1O2kI1SdN/yCayVWBD+UY8AMy6MxfLcAblmsNIttZzR7iowm2p1Wt0/rabva8aj397057c+IBEcflalHeaZWrlu10WbNm04+kcHg9k7evX0nPiIiDOP7ItAR9YRaMCRz+22iv9xPq7fVkv2pk5rC4BYAOjyUqFt23SSvp+ZHVoQGWs/pTtu21aDthzgs0s+jJ7Usy+ujusrttS7P1I/y09J2mH2485Tkjj3ljZvvEin+C/pact3cYyvAhwZ5IBmTfCZAxczCrCD76AjW/pFFgDm4O33bHQ8ErQE1o62DwIONxDtcMSSVaQf3riK1fZKYP66X41/+bZx75pdz/C8tMkY4em9f6q6qH/GK44/d9ZM3ynA3qRVFeeewUoAyAYABSxA8ZkHYJ0ts9G55zmEjIFvbzkKuNRlUYRNvCwLoWQ6NF/8yGBsv/Sxu1ie10xsI2uncDqcaYHklqT2Fqus3DOb1X80aeorjlz50lcO9rxsh1qc7voeIbzhxf9mx8bl6U9pf79MH9FsW8mLlgigAk4Wdu7xWgAAz3MBEF76KaBrqNJm1AA8LmwCCLX3ezYyFqZUWxEP8SHB2w+IFnvaMw6zB/1e7LegeVQc1SuZCWT0dF7qwofzUkfR3at19d5mvO9/bP7wzQ9JY/1K3I9DZcj9sOakL27/V0dsPvH4S5vZ7J0CbxfPOae657MvmW0OuINIcDOYzkZlIr74VoJ5EHSyVFXeXpBZloFXdItMsWFPxfd4krcsscGeCnxk3QlA3VzzVuK4hnxoujG4/MiGK71Rt7TomwVDC9EC4vcFprCsptPeFya92X97dM8DH3863yoIWweYwnW7LhkuN0d+Z92b6X5vdjHBHiv7YjubgxGZxKLJ4BJoAxNBN0gEnZdKXK0ii1yAXNq24W01sxcZAC3gZt/2GcN97GD4nwcxxuf9EJcSSdfZKW1qQOz0ddeaPlOXF3I89elV00ZfEuERXjX7tS1LzTX1Bz5/wG/hSWV9mVWX9K5/6ZZzNk6n/0EXLj/Sm1UbRvomH5+ul4wptQNnegDWZorOPAqZEiDjK8GGPge73T6RNX8OPFeuXsAGq2zJAXy7SLpbasl270IJLE6sKba5hvasuyWSxbj7BMbBCfPZNoA8o6OYljKQODtM1harbW86rR7Xnvf702nzns2nfvbW+l1l67FYyM6b0brhnB87pjdYfrs+nH37oFft4GZd9zUBnoMkAAiSA0tmRVDDvwTSIInuixfVXRmDW7JQIDFsu60yJ2zq1WYeiwAbqltajold09BRQdfxKGMGeX/v+HvIStdWMVxqwCrtrANEjW4g7bD9FiHqIi9+TxcgnJej6exrfKXyyCNHv1P/xj8ufAuvHZ6wfOW8t728mfR+Q1ecr9KDMm2dJYBwAa8TXAMzB7R9yoIMQW/lWQAqbHVlu1sLJALm5XgGI4EGvGKvzW7ZL+3C87jYSZ9Kn7H3U0qc9sM6eFIbRTU8l0JQbRBlsh1QEJJscbXWkUeXF8PP9cq2OxCQfOdnVNVX9Sezdwx/5//dKCkFIlUI+c1nve1sfcL+Z/2mOXffdDXHRCaDSbDcTpBoY4OgtTy2vHk/2sgDZJEtoOR2i6622NhF4M1l46EA/DmtFnieZ8leZlEyFOC8GyGvgp4bdJ7DUsbwYOrE4OFLl6Z2dJFJudw+2z7Kmb2Wpa+fwt/Y71f66srfr6xWl2z53avvFGvmKV9z0r/bWveH/71f98/dN+FbebqMUexSW21B4K+bUUvFasAS7TlPH3VbFrOYT3nstf20NZOsinXVjq+SMm7KIj9ljHDTtdrBl6Lwsp9UjENtf6ilQwlitJ+vdw+tt1LTKG0DRz9pJRsTNAuWtmUUx1ZHE5D8k/oe5bDX+5b+oPr1m97y7ZuYVu+66pLh5hOPffOgqS/fNyWTnMBo6EUUWD204xXclHEG0i58xDp6HbrJZsOPEnazbVmyuOhjSu2FMYASWtGRfylf9MzyW8paVFqpE5qH8L3YNSB09LLf1IyTfdX2AZBMFkBe67ngkeMBa+rG3FFHH3rKSZ/f+ur3m3OPrKc3/NArjruhGZ9+zBYdmG/395Mw5FVNNkjJ2UJ2eNTkpQwZ44wE6qA5M6RPprYZ5b5IU5yALr6+m0Ed7XDONqA7w1TLpmnTyFg8CH1VylDNyuNApbQ+QjdfY5mBbOG7eejfHGjMxliuaBZgAa5kGHHVLURc1DB3ivh8CJkARg0Z2aQjk21CyAXPrNe/7PSNkyOawfCIlzZVfe7IwRMX4QRtEZwcjOAXLw0WQV6kaTTZACQCiU3JyGaAHgAiY34GPORDNoKPTvqDrP1i0kGj74WWi8NbvH1LP6ks40a0bbj0owZ8v9SFvR+RRYVuz67MfbJvLaBJb7NLil1QCmDEijv8Di+yEFrOv10ESZPsivBSdUFvdNSL+9qtXtfXc3U+OhLZ/7yFeWkrUBLQb97C8mR9C+BgxZQJJS3oVkGQknoRFC4wACVkalaRhBnNOPkqGL6+8SZ1fe1UGKvtTJcuQGki+u1DaQCoatH0/FYDaQl6wLRNMDgwwym13Wjr8DG8sprfsDCnFY05fz8tVDwWdXhgKTdLsNWxXMa1ZFULTuoa0LBn9dJHuehgvEMnTku9/nB1UL2yL9+/I77xwpfwAIQAeGTpaDpqzwQQK52+A2uAsBpTj8Cy5zN9rjo1CQCTGQOVfeS4YvSaEKgGo2QrV6jOWL66iGHGQzZAwQW2If12b8gFwf7WZDMrHjVf8UjXSPCWC8aBs2XLRXSz6RGZ87zE0pz3abUSNAygGl1iCbjHEgOXkLM8svmC0MqmYcsVvmgtXzTks1JH7ZgrkdBznW8XiPWypyahWKUC0xEAsNANb5hWbGKEym0HUobIJNm2Pvu9+ujEosCGpD0xDZugGGCuSp1d0na2xWIBaECMRSAgHQ2NrccXBUgmUnOQaz4BHMtFxap6gyF+PBHS+EySxSfpMis1slhTbXiF7xklH1pwqL0YGc1zgqLSbptpy3HmLeXWAZg66JqXNfItgB0e88F0O2bIaUbDvsIfF/vhpwUDzMgsTwlQMKAOgaXGFlniBwAKqLdHwFegZ5qQgTO44ukfcjMyrWSc5QC/L4Nkn2cd9tRmYQAkA9Vss5Jymxo7zngcSrDbccWCLP88Zjocuwp0JgDPFt22QrYMfssL2WBlW5Vtt8EUFwAJvKzy0wKKogFJAGC635EpdliUhdfSJEfW2bTfIMgGvlOLp7AqggQMx1i9BCwFBEhpIkN2+cCFaJ6AcY3xApJYDKoM0O9VeGyypNasw2oCyZZoOdE517yMtA3n2cfZ6K2VWx4SW28BZNQY5moXjPXJigZVW17gsO3GYDGm2ywjFgyKTJP+vJgeDIwgEMys5n0I4ivIrZQzUI5QmBNNgyBZt/VGvwUo+9D8sqL4olueMTo82yoySc9ujDdTGnilikpE5FqsVAUjV7BpVirbJEMwUATG4wGSBotAM5D0DaSbXiBso8DKJxjOSPcEoC5iZjyF8dZKXy+2ZAddPPX56oaBFG0quXiqgwuMK35uq4DIhRil9u7BmAU8tXHb41qCNxV0qP0m26EPBZ7pwUoROkEgZF40JrnT8iIb6UIvtRoteKUtXguw5m3Z5IkV8qWGDpGihjNxWvUJrO/ZmCwCngMrTQ10mCETc4DYJmlKK88tzFk25ZHzNgaoJBlzcLCxEaD5gTf2JKnfgOoAmUArA2d5tno8XbjwuG0GgGyjmYXsGgUY/LDXLaDqo2wq7zgTc/L9KdOCDd0lCOGV5CgA4Dqqtm0gguHwYMm0NGrgkuZMVRugrJJgI4/51PMuZzBTDpulD6nYt42Q4SqfljIxHZVFwHERJybNSif49BEnaCkT6AggMy0TXkUYDCRe+sqRTEOfMKvtWwiCyucj+uMlAKktM7Imsy7POFACuJl0nJFsvQZeKmzZmOGMwIQyNvxMd0wTnQlkCX+j73fPVUyCRNH8OlyRCx2eJUK20BVoA+m+5tsBJrJQSi0Yahc93xtmH5pfdqBjgzFlsOh0ZExigWhwZSLgoawZF2ERfKGBbbKH4KuNIDAQlAA32ugSPE9fQUAn9LM95ejlnKMEWOX8iy1YK8rbKL4kaLoFMXjS8PkIkJyN1FpAuBqgEzX8wHr44HWmyQcfNv6GhKdqf0V3CTm4Mbfw0ubEt2WbzjHcThlnmYTkDJGpy1MXlAFuLXjWlb9demlbB1u8mBO1Ot2XaUmnbRDJRLQ0wwAJTjiLricPn6gYQLhm6F00r1qAQj8AswU5ERdIBE+TA1RnHzLcRwpIpRDAxbaZAJXzT9db3ezTR9xaasrAlI9skh9aX1wLYYd565NwTUxE+VPONrmdvuI7bd7wPmZC14FS5Tm4z1sW7NKUomNCgxjTCUIwlVmeK7IG0ELWcx+loleAKzYW+piTYDg6r1kgQYxh0QVElbg6xU1vq8zY2sLMrrs/B0RdR0XBT9R9hWr90I3MBTxsEqgE0luiRtRZFzJl0iXDsCmnfP7RJuukywYhZ/ULcOrzj/CzO4jud/q0CighAeC+ZJcPAQ4Tll0rpV/oqx92sCnd6AQtYhQCoqMVtwFFSTUyBkO1/DSQnX7wZFdAxeM0dFNPKr6IK33rJR8P9OMXYMFjfHkRNukKvp4ubLyUibeZrGJEU5kWQaB2phEQ8TLADgoEfshKR1wdg6eM08C+CCJ4bIXI+KpVzqTMTFttXLQwScaKYOIs5ydZyzjzq1d5o4CQdQSmEVgEkqtY6rhSRbcU7EXPN+n2EUqhRSuuMudaPvKZKy/LqsG4gAEJ8GLinidzNYMsgleyyX14yW956stW0LOmTymguau3pMciCBHb9x/eaTgTI0heZYFQAsXk8YsB1CgrWrVDgFOSJ/CkSwAtD+GbhiY2WP0ag+DRl15cjKjtbVN8WFyc5FbLfabPUC5i0Pc2qREQIaDiExsKovVI3/+Rrn8PCTsSbPrKCoLhGUjLflnF03FLspJ2HL1zBFv+6UGkPlf1AnSgJcPVsm99sItOxgVrDJNjGWhYBbzUD1BTxzQLSS9r25Mhu9ylpU4Zp3hf5HsTrk7lQAkWAvw4qgRQrIgcLbGYNEGi2+mLAA+ab/KpAylmk9kBO4CdaYJxjgKk2hhUJnmVG0iRfYZyVYsfsgdd20dc7OC0uvoKdb1hqRqec141OH1njIW/o9VqdPNN1firt1oXff/Ac5Qk6gWGFbFMZz6efNX/F+dXvZ2naLihBKWjOcweebAaXf8P+ktw+g01iTEHSu2rTDfDdAHTFzkISI6AAxZjMx0DAC35GLQ8stA6MmqGrogtHaI6jKUQajuVgxqI6SET80UBSvQNkBj8QyD66Kmvn/lWKp63ywDHTAtIqD3rCBWWBAoAOQO1XTJ6uT8UN8DSni8vfQ7jp752Z3Poq1kpW/o7T642/fAbq+VXni/CvOy98srq8T/4/Wr26MPSi/M1uGUeRJBx58UZpgU8vPC7q6Xvek1VbzyiZY5u+nI1vudOgag/LmVgxCKIAELBnIFSrfF8yhTwErSZgJo/HCDGUipg44mzUvq2qT4LhOIhkKftTtQer8eFjYjeRgOaVsGZhgVN2ooEUMFFnAgawACUeDILzBOi+FSBVgBAC04AqZ4zPcH0WaaxZdMuqy7nYjy9saZsY1cXQQ3A6kt82opnmuTwzDOrwWmniLZY+qedVvVPeVG18vCjypbYVZx9MUjsGBqR0RwWFpMKofAfBWOO3cJOAZMtleBnwP2cuICHIdOR4yU506Cjp45fKVf4ZVEs8NFFPpyYb9/0RUTXC4AnNt6u5sLyNLUieFYQyRALOAOoXkCufpuNTBJB2WKynFtqB19gQib3FQyfLwLStxnaXwy2eFxnNd42pSe+VLStanHw2M3A53bKI1+dW/1tW6vB2WdUzbFHh8+d997OnVX/rLOq1etvdMayzbNMABK7eOOZKha0TeMIcCsk4MyLaAq2z3dntjiICSzbxY7BFJE1Y1nFyWBGP/hqO/jYy1fRsyxGVWgXcEuf2jrUCaJirWiwGgkaEpRogE3MTA3ZMwBS8BAtmLAQJCAFWAXcUsUAAGI/qTjB1Yh8iOepPMGRD6wsAThVBNr7PvY3URiCbchbsJ/caDwthv6pJ+ssPEXzQW6xNJs2VcMzzqz2bdtRje++SzFh08G3kF04E00KAGM+6+05eM4cENLCk4gBYq4isW599VvOSEww1wKMg48sihbOOmUKzWOkrm2LTyn62Y2+Bu7rwsafBojh1WQBgu+4tW8xMSkAnv7ZY9VxFkpJwSk3/PC6V6yGVuD4tsCLgAyUDV9x2mTYJHOZuMC2B1zwODMgMXHGwCXedPO/vEFZqK30lBPt7/7e+qedKpBfVI3vvVdjxnaPnO2Tld5Co2d+zq8Avd4ma15x8Cuj2WaV7BIiEG3POdGMWaEpkgK1BR8TzJkFKvDAyW8toMSWV3pCgErbAKuvOHKwiBGrMLIxJoWawZDwnB7Z5GiKH9snweUgJ7gFWLU1OBck3iqVBdwflqcpEsSqs0n3ApJjfIFrYHXBwwYBDf+JAjzcMsqi66e3fXs1POu0qtm0UYz9l/6O46rBWWdWK1/4cjX1VSXbMb7hAQZV5Lfj4rfgRbKaEDIhKFnmqZ3C55tsAIiDLFmAoxhA+eztUH3xObsNHCIWSz5TK/rIw+wsisLzGOJGX3VXVoHhQ2HNQ0CWSeUkPU32CBcmV0CBEAGIjDMcSYMer0KNpaZRWCjaCuMWRBcoOO8ZARpZQp+nNwGqR/A2yyM3FYE54wNlanXZRoennwQniiYzfSwu/5vN/jqmhAbV4EWnVb0TT6qmN98sE8yTUWVBwwGkdxPTRI2B1HMD0XnBX+lzYeVtM0GKzJK8+bJInFBnW2QQbsghWB4bGtcy0OnrhRy7Ajq8oFNcyS8WQZJMc0cEtmZA7D5MbjUdwTUrVMKmSNeX/BECqUQgVLkdgcnMsQYUCl5Ilqs8rjCVaZxLPLEhQ+PMVACUsQQzwAofplpMAR0+izYcVMNzdfV5/DZb5m36+JPVnr/9XNVTZm589StlIGbdP3VnNTjz9Gp02x0eH19Ym3BZWPTZVh1YE6HIgTXFnvDQQr7HrQJG9BII1i2ZCCioA5yzSu0CjHkdPvprM8/go4ONtINezsc03uAh68du9NqME6MUnw/qKGihgR21DSYk9OAkSPAACRGPEPLdR3Fs2yyaJi9svIAMpFRx2raVedwTsjLZUtXm6pR/9URCysaeL1pO5tslUooyvu/Bau9n/6nqH3dMtfSKXVVvy5Fm9LZuMYjN33+pGj/0kIbxQJoy/rID4K/aNHhpnHCG9mJxJvsCiTNM4g6uZMgIComuuASoCMigk1801b4Ag1ZAKaBCY2zzpFfsYtMLgAYFewhm8bjl6tSBZ9DCVc2KZ3IQk248mSSk6Mhh9R0DhFjRAMmkCA2CZJfAMygEjVOSK1JtS85AiRJMZ6CA0oKa2oba0vW5i0ikpxpyWhk4fNHxUNuyevu91erNd1XTJ/ZVo6/d14LI+ANdxfZO3lmNH3xY8vhGwWk7jslCUTN8dkCDnO/QQaKci8xVfhskWStbXmZWgExMpYcMdQue6LhRAIJnuaxLX12XVg4diMkwncdu3UmBmQsNBdCrVc2WHmPRDxLvAYxXs1cxjmAEMOEz2dgm2fd9oaNhDQ7rAUck5w+LfYEEkGxz8cCc2454SE4W6/no8nK1xFZ69GYGcZnu3lOt3Hp3NX74Sck+XI2+el+1tOv0sC2J/knHV0tnn16t3nBrNdUjuXZrFo9NKOKSM8KfEiRbzze2R2+nQoQnMkhJ0XUXuAKAAZMQ2ZIAsagNusZoL4oYy/qStQ7xy5ddkY66Lc2d7HPe6jpDZ6Il5ExMgqCHlgRptnQUJdW9CGIsAABs1b6KclNvyjK0TbcpXcB4ayS7yDLMs0SZGrIKjG2g0slYX+iEdzwJarYeWW34lrMy8lJTGd319Wr1Ft1G6L+dGT/2ZLUqQCcPP1b1j91ifrNxueq/6BRf0Y7vvEtZowVijvz06LqpYA6J3wFvMUCA7RRtBb49C5lMyTa31dePz06AMTgy3oJVgMUUbdWSsT3L0k86TPjl5UVGXwRfqHGfGBZEZUIxKVfqUdpsdAc+9lQbOPhaKQp+AGwhBLQ94hR00TjbAENgxUdGmjE62OGPs7MVAaz5OIcdQGejQE482cPb4SnHVxvOOxWBKLKzctv91eqdD2p1D/gfoQTivdXozvtbEBEc6n5yICDHd93v6bF2iQMv+44Qc7HPENcU8TgTfXVawMgs83mHIfndZph5smFQxKNvPguUfsjbAWQKjaZ1JEyb0gKbBDstOo8TtQi0r0lY1tnmrMUkukWzNWjQUtkSCVxgmbqph3wsDr1LLj4SCrs+L/P8M5CsxLzQwRdnpbdTQMeO9Ii4nps2mzdUG16mW4Yt8wfTk0ee0FZ6r7dS33NqHqv3aEu94+vV8nlnKHFIEc2XC54zT632ffEmXck+rqkw5/RJ/AKq44BP64p88HaqhUUciKfqcpMeV6yiSTVoEnC2oiYiQBiMoKPfAs5wZFgXvCIrOY9V+uq64AMgKlbyiEkyGSxlwCw1f/NUAy0TDSpGEOct20EXjcwTzSq+P1QmyQlvxSaSWRqXM1IgRwZG1jFW46sCzsXIQCbLTPrbtlQb/+UZc8fUWr3jAV3QKLv0qyS1fj+dAE4e21etfOWeauODu6v+jniuCpj9U0+qBiceX+27fo+saXymoNc8+zS69GMBMmanaD4zX5lq3TM3woYI8vRp80YYM0PdxvfSL9kHYFZAFp18qbJRaLQtB8mdsO02MRcdEDWPPBMzE4thsbrF4DBbiqrIjuiCVFzAEBAZxz52yMAiwqp3tsEHYE1CdfspvGwzRnnIDXzEQoioJTl0hkNdnJxULZ+1I62q0la8cvsD1crXHpEomRuFD3RX9JecV+/8egsinMHJO/SQ4GRlrs5FrpBRwFU17DJzESeihUa3SBC/eRXg7KRkMtg+FgwugMumAaQttQKk6LEIsKWxWgCxK1s4Ao0628U/T7DQ8dNnoh+GSDiWjING4DxqWzMtgpkvPIIXFt0mwxx260hO9ZzGBUvQ/H1Rkj/7fBHYH/62tmNlMf6U8zD9mk56VW/zEdXGbzl18d7wwcerfTfdV00e5TM+ZYh3FYIxqEb3PeosnY3m/x8JNoZnnFw1xxyjcZkDY6Cn7wSQZdzI8yACoNYVxYEzsVzc9JDTy7Xm19N5bN2kQW/7ySs0MggA1Pc5zlmePP3OYfAYB+DdZ06pQ41/0PXrwmSjHrv1tH0BFCXeJZU/AAw56e4iqz5gqsRjK606Z57okL1FwpVkyVTVNqN7Rq9cCYao+rTNzGwkOOqbI8B5ojI44ehq4/mnYrQtK7cpC2+6t5rsUwYNdeWqFexzRlfGk0dXqpUb7xaYj1TDnflkR6t4oAujwcnHV5MHHhVwfOdVPnvlM6XYSA8EInuog6wa7/mQ2ruO4mqes4qYEGTmLt/hQQcQysL2iZx4sMrW2cqISICgU/CzZGGhp01FC0r3JWGKKrdgmR8090wLuXIz7ulDN4ABHkAbchzQT3xrnOxTh6tOtlRNtDwc50YfnQCeK1m5x3Z6RF9XpCdVwxPm94ZspWMycLBULZ1xvJOCOWbyaqvWn4nVKpg8/ERVFRDF7u/QBY6yceWGO3SOrkSgRae0c2jjEXS/Y5ts14sPmbW25DtAqi4gefykGUjpJC+2UAkUGfSdkUnDeS8GMdBBjlfZhiOASffgwZOIv55hhK0hSlvTVlGso9DAaiHR10uDB5VuyDhJ3UaaB9ySQChBBRjuGXE2FoH6jkqefxImoM5OLYC+7g2P+NZTPBYWXTS5zRefW23+7nPUbT1IZvhh//LqNBl6WKD/feq04wXmNm239ygQoIBp5qIFxeICgHUFIUdeHHzPQBJwxFW1ATcgyOvlixTV+uLWHBzo9KVjwOjTFgEd/ZheeNQUV3pDlg6+y4jvE7nh9yqEV0pXTzQHtfCIEUYyw6LLewJqgt7En/kbbWrz4wcAMAEIUgDszyLZO+UT52d8DVGZyGrQFefS6cdWG887QQKLhavRnNEi45/pDU/eLiBPrFbv0n9eqgB50cmhshzXxQJ7Cq7PQ845Z4d8FUDeSYh9Bry9wQcMvnFHmHiy4nEk326n2AzQ2mw2WJItMmq226nthx9zoJl/+9gN6TUlM6k7IU8WNLJ4+6OPejDVo28CKKkJkEJIpPgEH1lsKOt8m4EYowCatirdksRuqwBIr7dxqTri/JN0YbOUoz77qqdHdkunn1jt/dJt/vTDtz/4R2awupwia8dBQEETiD7rSsaSPegR5Ay+b4kkGmcjerywjRw2oh/nt9r0F17IIqNXLpjQB/S0Q4NdRrdWeJRU6mwuNtzzG/NDOUXdheSG3goLkIpM2ifX/bAcPOWwF4fkeDjOBMg6PzNVJHkgwH/sTFAHOzZXm17Z+dyQ8Z5l4XJ/cLI+MD5pu+4ZvxrBVsBwFc8IHlPKKeRo6vnKkJAhSFZp6viLPPGFXsBwW6oC2Tf/gO4tFBkJ66cFH1nzgm4/TGMcHEHHjazDR1+hih3bqV1HSAXvSxEpqYuT6sq0spIUPVjxHgFBILZGTVsGBSZbJ1urAWYMCJJWZvozPmUjj9nqpWG1Ydd2XYgsfhFqdPdj1X3vvaYaf13/EYz+iJ1/qwpHHZgA31+9UJ+FsXzOjmrza87TVerczvDEY/1JyMqt9znj23kSbM+6UNSlKJC+hQG5kh3IkX0E2YFGLoCAHplGP+XUNK1c0Kjv4u029awveXjoYbcdhyZ9+UiFH7Ohb5RCyFQ1u0WyAYeIUmrbrQyWshRmOVuUSV6xZKUOu9hWaSvIqPFslYDxA2CiGUAtaa9sttItG6pN33pC1QwVuCwzPRvdd+vD1e7/c3s1038AzDnaYIcY6IYpJg9NCnxPVQtk/NAebZ/6OkcHxGaTPg05dUf15DFHVWPdbvCVC18Vo4eRztSgmMB5SDaKz9kXYgmWJtBegSr4bZuJtRlIG718yZTlkJfD7XmJjv1AnqHTXpfOts+9qT7Z0d4QQvvxWoxOQa4UjIViocxrZZfg88Bx7ydZsk9RgaNln3zI6ZwAs4T3J7JWTyEUrKWTt1abLlj83HDy2Eq154v3V1P9Bz6NnuLob7FGMKk9MXW9dcklsBB9JJ2Vrz5cHaHPGgGvlIFuPYanbNfnjE9ofBYPs8KOI1jEXIuKYQWbBQlfwoDhTFTX4DBgyAU9+V1Qy1baBRadLrg4UmgGjk7SygIQxQ8TBnoc6Scx9hDBTlnT7XA00zS6QFSnqyObuVu64YcBniNCMAmXtk05ydMdtlT+8dxUGOrecFBtfPlx1XDH/GE3w40f3Vft+Tz/OZrkHEyWh2zJJB8yU3z34hYj6Z/+cs++2x+qVu/eXS2f3QHxOF3g6HZjnx4YTPetSF++EbSFiaQhaCwyNq8EzDsN5HIVClh6hQmyVRNmzpg0eGoUEMtYMP09HHh60e8CyvDQZCfqlEGWpzaaN/sDYrQXS5cg+XlZ6MzJtApqnGkLfUIpSt7kkzAhEDf+/oRffnAO6i/uOqH6246oNn/74m2F/vtJgbG72nvzbgVIwJPJthzOTrUA+KUaD+0hRCcAeq3e81i1qmesy2dtz7FVDfq6wDlWX+nY6uesnHmRZHjvGdiW38SIWwz5jK8EUS9vhwgAmMeiHWM6tg42sqJjHB3JtuPkgjCAtqO3IoMP1kM3xrNbpc2YE/0pqXBWAjl57KwrBVDEXGi0SHRo2SSbaErMFy0tuNKiDYpKN5vTm4NHZgK++LXOwA1nb602vuSYNBjVePdqtecfvq4PfvVXP5fJChXpsRkzV4qvFk3RMDkAARvvXqn2saXu3uuzNqT1XP3Eo3U2bhfIeoheQGitFamsMcQjQYDBdgFFenS9sNjK6QGOHySQnYhSS87ZKZ4zUrLqt3SMMBF4+FIykmgW39Bv28RA34TXO1EUw618W+jMGchRzOZtrVzpZ+0tk0H5kXLqezhtTeVjKLMIBJnFebh5WVl4fNXTltot40f2VU9c+4BIPu3Dbac1UmHcth0JQYtNWHrjgmjljkcE1u5qgy6YSulv1UNxXfT0brinmuhrHt4xfO7lHFIwvuTExQ/ZKj+xjQhAlmAXUOVeuzW3oEm4zTr5I3rJZi+KAjI21bYsA9BmAhomFo/aJumNRaKNZ56JJVskGzOnUQpanRKR6hC6/G47RSTvEDNxDi+V6NNiW1RPWeh7Ra3Cmf4W5GNXP1DtvZX/S1JhZXVrKx59/Ylq7236QFfbIHRsxGglG0sPKNgNQsLvsrty52PVwx/7p2p47Z2OvZUVJIPngzTC8eQ/3VmN9AlJvUTk5LPOrMkTe6vpk3rC5KtTjUNwCbJ+YpuVHGvLWZS1Aw+iEmp5alu3yMCDxlB6KwvCfdGLLnXRY1DanIn6+6f1Z475xA36FOMcLirWFckduHSYbnb665QII0W1Mgd/vITkKM24p0MmAYOo/xYUWcvrChMZ72QEVgFpuBol5tgAZPgKQARS2ytBy+BAQ9fPR7lqsrwq0QhGo09AfL+p/+TKwSQWtisdbArEWvejPALkUyOAsk3s5z1ejE0fHezgS/ZxEhveCsMmj+T8cMD64hmsIsO81QYoqcbWq76aLZDiD+TPaDz5ONPwepXamiKVQrT2nE03WMFYw54Ltq2iEZLeRnFaRrg301s4qHfzAIR7Q4IvMd9GAL76bBhszfxT8sZ543FEMY8ObWzKNgZMySbPW4mxgyeagZSAyFh2kITuAh8wDAyWCW6IxvmLMfroqmGH1TdgjI2uXqaLzziF13ko7nPRoCEbNstZWvqYau17PDkvW6ybGMi1mk+jMJFu8W64SOqys41AAIa6deBkuxNvyztY1iijGRKJy4bfRU+T7CHE0eDpPUDOhcEiMVPCIWQJpCm2Zrq2X4lgEjlfgWoA8z0QTPX18vKQTGQKyqLbBiKcmzm2n8xgj7H1om9ARVPw29sRQEUfGrrI2GyMaeBZIHgjvm3hKdupdo242VfzKYtngoQUn1VBX8YyWi2Q2PQYMVAASDvKvF/4eJK+AJJKmMygs12KPwcXiU5f8bAEcVEJwNQgQDaboBBQp514ZWtTvwVJ/HgumnoOvoy6Fg+ygIuMSj30JbLwbXADjLBe6PIqvhhg+mWO8gWa+gZxOspMZDSoVAcqEZcDcQ+CziAy5hnOa996iGNMQFfOLGZ4ONd++i6JuLXYj9Ood0osgg5BTWcBJKmbDyAZuLCoQOnH4BUZhAk4Ajp0WzDJEtHn+tEPIDCSem7C08tjFboNCpQynvrwczF4TLHML3pWIbP9bTe4WSJ2pbe+/uf46zUOQMGDBEoteqXvjhz1mWdEaRcZ5IouzdCEGpkY7LatWKGLTkkovlqjH9MCPDclR9alPYTtAxXgqDZ48NVX27LIWyfrFhzGjVsIA532LIu8bWkMYeBMhibAPE6xWbbYMi6127jAeKoZT5nOprpYFiO2yKN3AP5i1qxXW0/BiwhxeLRGwmwmRnglqTfqKPOWwTZRsqrBvetitJNn9Ioh0cAKqygRINqqYyzo2vqgJi+CjBIyuTCQoU1gpd+CQte24xwswJcPjVs5bHdf6i7cQ2KXDMWeQGvjYB35okeW60Fk7G4U6D9nBc8YjFLa1N0S/e75GVkaMs6gFLfbDqa2Ws1PPzl5BZdmHpJxVZlKKV/sxNQDKJSjX8DBCP6oL/BYAHG+QVKkzePME8dbIXRs8SptGurrx3QYpY1+3nJE1sm+7KAe+qnjvmS5tNawCSKGeXVKeJ8EOp2ywJvTD0CeC+y3xbihWUYJTzQBcbpezftreEyqFALRVXI7CZZDl8xBQRc7qkNddBH5B6HNOlZ8CKsWw/ahIZP3eqItbpvYBkz4DMObdIut1gZ20mby2gxFhQxst2gRJGpbruFJQN+M338miu/SRg2LJcTJ21/Vyu+PuYaGyXx1g7ogBV/FZrNtQtG1AfiZR5rc3FbqFQXziFkot9sSkWnHCRBjvELnqlYPBBRsdAhi+SgqbECHJqZUAAUfLJfAFX4LEHIGTQ2fhTFue9UJsAuAp7xp4YN9BmD/VhSjPVVpgSliEFRaenTLe3JLt62LdkvoNIL3VBIdYZpyuR1e80gIYczp6rVXoJ5x12XkFDjpEnmDQRsAVIcnHXAgWFgNwkWfANIo4UPXNosMhsjQzFa2V/Q8RoBmHsAUcMgs7KkfPqGjNluqdekzNm8q3HdO/bXn2T44JfjJDqHy3kYMAhJFugh06gXZOb1o2D5vvIgDjdKn644b8WaHpc1kCBOyRcbt6EdWhEq8z42GS+oX3TKuVQl+YSUQVrWwGBImqFKOsRNcjIkVIKlhHQxDzxe6KOmnBdN9aLyQR0VgGOSUtz50XoVW+oGVVbWQmn5/Fa//b9+br4RUSrCjd6B3rKscSPhA9NDqvKcdKI6Q+jmvWG2FT62XPOfSvciyTZlu3hoZRyBAAYCiHx+AKWiyM7fVbTMOgWKckEOXrZA+YNAPR8V3kNGfty2nvv2zvE4t19z4I6ca+4DFGGkjgNVYdpfxuHCh7rzQ8+2HfrVBT2z0ZebP6Gsp/Y+PZ2N+w7otnWZL06hrCiMdXLFG+5b6XpGlLXvdPsEqfUSYdAuICRAt46C4nYB4u1ObOtshqz42RGt11vD9qYSDTkCRV6BlO9qMV0AB7AQWP5HBhwJyAtS14fnYzwQzAWoXh/sBrGn08c9+dNqirY4mq9Px+LPN7smeLwr56/UZtwafl3WYzVmdlhyPZdOhZXPBQJwBMQHpeL688VIp4DiYSU/wnEUOUJFXvcArE0x6GMSoXuhQA0C2FYzIzI6e+SFHsOLpEToBXmunvZ+I7THAxC5jR+Aj2AlCGd8g5IKwnPjOJsZEFn38SRvp8xzwWCw+Ax0j/e+mS8tccF07mTQ3NLufGD+qxHxfgwEDIrtZFnAoxAPWORk7vrYtJUgUs7Kz0C5njmQKqEVBk2xXeFmRnih0SgDQZor0Ld/aARBkGJBgZVu1PoJepNHnkZrpKe9MlM1cCN46Wz6yip1sx/ZJZs71wg5sZGKsWEQ5hnwomW9ZfDONWnaKrbatOAnIiT5frevBb9+65dY9zaXVpau7H5n9yeps9ZNLNd+yxgFeURaAXOgUif3UiybSXCGqtnneCFjSTcNW25jzoOUk5usMWkzYHtiO+m1woZZ+qbG9BtBc2UEvgZacs0d9B5SxghdAYQfQsAuPRQMfeVXFB9NDNwAKvdBBNeyHvGyV+TBXG5Kv7RwYI2Q2bDiiGo+mf3bXE3d87IL6ghFeVK+pXvNIMxlfPq4m1+t3jCCpFEMHvn4JuQO943y+YmbpV9o1r6NbHDd7jW4r27HXtZ3B9BpLMH0WYh4wFmgxfpu1DowF9YZ9QjLPRNtcm0WSKdkX8vSxm3SDEX0vAgNR+NhPQFxDp591TCJoC3MM/oaNG3UWjv5+3DTvPPvYs/UrX7EEpF7PLnz8+2/SV+rfPK7Gn9bv5GoaxtfGPDmkPVCpw+g6WgHD8p036A4mZtCN4padpV9kVCcw8yGLjiZs+QiGdSxLv9CwVfq00eVV+GWFB41f4gn+HDwRYuWTXUr/2ISQK9sguh15A1vGQXdNlmns1u92UaS841F0iy/U0Wbsgf7E2fKyAFxZvUrfefjxLcvLd+oBQwu5RJiCgNz9ff/Qe6T3hsls5T8r0Pct1UOZwThORR2TNanzVngdUtsUrwtSsYOKQU0+dGh+67Qzi0wvK9ygpay3Q9oqanvLMU2Bd53BkB3PIXleJA6e5lbksx/BAyAcYtFgo4CCHfWLL8gsgAIPWU/GcnFGYgo7qd/W8tlnBL7neFmLIDP65p/+ArKaX1vZu/Lzq8tLbzpyaemGAqAMGmrqtryyuvihux594r/qs7qLR9X493Q7uXdYD2QWZ1uxeaNLW2jT0cs0ajeiT7ublclqA0MfmVIzmvVNCDquGxgzRSNApZRgIR/tUs/PGIHnDEx+BthgxcAxZkvHFqXYy0VBPw/qckbOwUieEPC4elBbPjfNSYTJ9l1jlHlq3OUNG3QR23t8376V945Hs+858silK7bW9aOteDaKZ2vp7l9X/enw4aM2f6cWwy/2ZvXFPB/Udrso27VgB8QutE4/fMPJVBcAbgImL35KPP30Img8yfBzyZII6NFGhlfbl13afCEJO/7+ikiWkXz2fYuXutBCFntqowuP20BuAVwHjTH95SbzGUfyai/I008b4R820xfx+HV0f2GKWl+/t76arV3Ppa6G+uP0+q0wXThPr5yMR7+2ZdumaxQD/eLJ/gvTPWDZpSvXV+3+vk/uebh+vZ4GvEWv6xbOSxxwUaMAVkgFrZbVCgdoyKHT1QukYYQVJmV0O7JFp0U8eZ0M0QChbzvYyj7Ba+XYvijw1PaQZFehhWxkFbLIQevQF87K4C3KS9zZjs2SuWmDAUuGwlOfJzBLww36XvX0C/rC2I/u3vPApVuPO/LvngrAsMz70yh6bll/+tiP7mimG36qN+td1m8G21Yr/c47uvhVSgGl0DT3Fghk4DumohJUt0VnFaOjN69iOuVoES/oc74zA10yqGRpyT7onczDdsO5R1aojq8qhoyPQz7DY/zMQLKp9JFvswv9zNjIKLm1JoOdVdYJXmvHfjKGbLM4cyzm39P3aJeUfaPJ+G4lyvv6m5c/sHlz/ZBGizWlxlMVpvu0ioadfeeDb7x39PDn/ovWzMWTavT7+khmJc7LYkIOUrKKutPpAGjEWpYabuvN2UJdDMEofRHNhwRNfdgIOzNpJ91kjJRX8lTNs402fOlgr7TDaPRN9yCLfBtJ3W5GKvPMoibbbCvk6LdnIh9kikfm6dfq9qysjD7QNKvf88mrl39VAOr30J8egJJrvaV9UOXK6sqlLUfXF+npwS8J4O8iAONa52WZL5PPts80+wwt6BGzFAAYzRO5yEK5QvapzPvKCEisYOS8otWXrs8WzixA5YeMoU2GQifLMmMjC+hDjzPL3zxzZoStciaWrKHfSDayaq5LNvrMZRzOyMwyj1vOzJJ5OgO7Yw95bKY7BH395K+Xes0v37l62zW7du1alVcHXSJSB602V/hU9aebBsdt+dH+tH5H0/TPmejCh7+p70UtMU2ZN71iEtZUPOLDWfUKgAgBiHiWB0SDSj8BwY4BSbkEzVtTtsuFQwse9tEBpA6wBTi2P8jefgUGHzK0W6bHyr5thJ3Ywjt2vRjU94IKW15YAIgedIOoYZb0J631l5P1jfsvjqrRFatHbf7Izp21/pbLMy8a5dkX1tPfHP3RE5d6R75dwXmbftnqmNV61fuBs8cAMo6GY0QqggudPpNMGdcEsvQLOCVAojtA6Dvg2FIWAIQCFkELWpyBahuAlMnMaLM1wQVk6yJredlqgQ+7oSO+s0zyCVJ8Wzz18El8Zyk+chWK7/oVgWX9DwLj6eh+Afi+2aD57e3nbXpA843dXWrPtGiUQ1c+VX2qv7Rt/BJ9ov4L/aZ5gxxc0r1mDMCEKKoIUjRUZdsgMFlY0Axity8SQWtBlBw2Cbhi5kWBnoJoUAEFYAEYuvrzixvJlO0VQNAn8F4UuUV2APS42NX4BiTBc7ZbX3T8SADLtsrCaPQXLrhlmFSTvRrnw/t643fvvH3rDfWl+jvYh6hodoe+cF4ec+LgYv2vbL+omL+K851N1sCoHVmocROoeWYmD3DgEbis6fveDRZ0gEEOAAAEwAiiQevwkUVOgY/7tJQxcGmjBTjlsJOAxdZJHzu5IACMfgIfAEqXsRJU9Nk2vcj61Sf120u/+uADR/3drku1RR3iopGfu3Ll0Vdu3rLcf3OvGf68vmh0yliLb6pfyVYINFsmHcPTLNlncOATSFXuIyAgIttQBdCUKaABotoOJEFOgOOSP+y3GWfAdRYyBm0CnwB4USSAkYGMFTL4ML+QwTfGw4+QKQByyzBY5lP36hYt3l958N47/+SlP/ZS/X8Pz03Bvees/NHeP1rZ+fjpnz/tqOP/l6La089Zg3qw5L9nAzD6MVAEHGDoA4Rr3EowYACi6VEHuJJFHLoQKnxnqGhkTvDRRy4zNu0VWqmdzZJzNiOjlyvsUAotbQUfOfEkowlWS8tLAq9+WN+W+MB0Mv7ZE19z9P/e8bIdhzz77E++MfzzUq4+6eoNs8HeV+lBwTuaXu97FeH+mD+HRKBYzfx0ATRoIpqHjNwkiGQMPLLAAU890yWT9Nj66IuPDXR4aRv0QgEIb33qZx0XN2KUTLRuyEfmyw5br+jlCtV0yQ+X9BFeM1ud1tMr9cTlipUjtn3uzH9d6298PPdFXj2/5VOnfmrLcq/3+l7T/Iw2p5fP9AshviUhSwgOZQE4BZVgJoAF9Ha7FPDWk85amjOrPS8BsgMcdOyKZuDV9lVmARx7+NMCKn14nbMRPrcMsWBmn9VB8e4NG6dXbnvdNn7F+XkrzzuIObP66rOuPqFXTd6qLfat/V7/pFUeFPj+MoIdYBF1kQkotTJpDiJ08REh2IAJIMiQcaK1GWhgUsYghEzJUoMPHWAFmm1IP85MwBYNe+aFXE+/rDrU39GZ1JPb9Mvm75+Mqg+96Ce287dZnvci775x5f3V+wcv2/Wyc/WL55f36t4lOjU3c0vip1UFFDw0iAQSMDOgCZaDyzYMmIBYgKVf2gZRBAOLnNqWDRnrkXHYxy7yXVnozkjZV7081NOWZvqIPP3jXjN57ylHHX/zobxlOFhE5O03vlx7wic2TrYd9yr9T6U/V/f7r270SShXsvMszMAKQGeda9EAooCtdgEtMhFA4KdOAdpgdHSdmWknn6q0mVlsJ8ADZZ7GXJ3V46um0+aK3uZ915z2b0/Tl6+/seWwALGE4NMv+fTWYX/4Q/2m9zO6MT9vol9jmjT8wXWCDkoAJekWROhzkAI08Qk+mVRAdiZCT/nOlhoXOgCul8Bq7TGO7fAHDvQ7/LIx7dXXTmfT9zSjvZ84/T+evlsSh0WR14dX4RHeZ87/zM5hM/yJXq/3ll7TP0HPGONjOXnr86lkJMCCLWBxnjGbsoWarjeDAUjiIQ+4BlhtaNn24vCCkBFAVsX9Xl9/nnrajO+U6Pv3TVY/eO5/OvVeaR1WhWkfluXa868djPv1ecOmvlyflr5RT1s2jfwpiT52dWYprAYNEAMQb4PONmhkqAQAirbpILN/nkGUvM9F1cMh4M12S+PDVW/83q+Nbr3x1e969ZqvNRweoSMMh3URmBsnG6tX68LnndpiLxIY+h/48hGeAVIGup6D6exsMzKANNACMDJ3rlMyl3XA/eJQj8r0C62TWX96lQz/+kOPz67+tnfvfFafMjzXAT7sQSwBuPrC645eHq68qe4Pf1r3mLv47JI/5hdZJim22MxCb60tsB0QTZtnaDc7tXX77NNntV8Q0NZZHqQAAAGXSURBVO95cu/o4y//jdPWfSmp+HM41S8YEAnau6p3Na/7vtedPBn3fnI4GF6mD1S3+ItbBZysW2DVX9xqZSS3VZ+LPlv1p6T1nU5tow/p7P1N/YLR75797p36M/1P/5N1fPtGlhcUiCVQ1+26brjv1On3609rXj7oDy7UXzBe0rNKb5W+eDF4ku6chWXLLXw+0egLPNV79fne3+rvF/zWk08+eNUFH7jggN8qK+MfbvULEsQSxC//4Je3j2b9S/W56mX6+oQeGugw4zNWg8g2yhYbYHZpbJ166bfdJ1+u+9P37V2dfPSCD5zN91pekOUFDWKJ+D++4Yaz9EtCbxv0+j+s+7kTJ/rKph6HLYDI+dfT38zu6eJF2/Adk+n4D/Wg+vfO+72zbit2Xqj1NwWIBJ9bksGpG16hP//+48q61yrTTtKr7z+SoGyc1PoOdVXdob9y/JdNM/zQdY997kuXfuRSIf3CL980IBYoeFhw/SXXbx8Nll48mU7O1S3fMcrO+2f92fWTurnxFR8886C+DljsHs71/weO8aOJggogMwAAAABJRU5ErkJggg==
'@

function Get-HiveMark {
    $img = New-Object Windows.Media.Imaging.BitmapImage
    $img.BeginInit()
    $img.StreamSource = New-Object IO.MemoryStream(, [Convert]::FromBase64String($HiveMarkPng))
    $img.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $img.EndInit()
    $img.Freeze()
    return $img
}

$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Uninstall FMDK Agentic OS" Width="640" SizeToContent="Height"
        ResizeMode="CanMinimize" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="14" Background="#FFFFFF" Foreground="#1B1B1F">
  <DockPanel>
    <Border DockPanel.Dock="Bottom" Padding="24,12,16,12" Background="#F7F7FA" BorderBrush="#E6E6EA" BorderThickness="0,1,0,0">
      <DockPanel>
        <Button x:Name="Primary" DockPanel.Dock="Right" MinWidth="110" Padding="16,6" Margin="12,0,0,0" Content="Uninstall" Background="#D12F2F" Foreground="#FFFFFF" BorderBrush="#D12F2F"/>
        <Button x:Name="Secondary" DockPanel.Dock="Right" MinWidth="92" Padding="16,6" Content="Keep it"/>
        <TextBlock VerticalAlignment="Center" FontSize="12" Foreground="#8E8E97">Powered by <Run Foreground="#A3119A" FontWeight="SemiBold">Hive AI</Run></TextBlock>
      </DockPanel>
    </Border>
    <StackPanel x:Name="Confirm" Margin="24,20,24,16">
      <StackPanel Orientation="Horizontal">
        <Image x:Name="Logo" Width="32" Height="32" Margin="0,0,14,0" VerticalAlignment="Center"/>
        <TextBlock FontSize="16" FontWeight="SemiBold" VerticalAlignment="Center" Text="Remove FMDK Agentic OS from this PC?"/>
      </StackPanel>
      <TextBlock Margin="0,8,0,0" TextWrapping="Wrap" Foreground="#5D5D66" Text="This stops the app if it is running and removes:"/>
      <StackPanel Margin="12,8,0,0">
        <TextBlock x:Name="ItemApp" TextWrapping="Wrap"/>
        <TextBlock Text="- the Desktop and Start Menu shortcuts" Margin="0,2,0,0"/>
        <TextBlock Text="- the CLAUDE_DIR, FMDK_CLI_PATH and NUXT_* settings" Margin="0,2,0,0"/>
      </StackPanel>
      <Border Margin="0,14,0,0" Padding="12,10" Background="#FFF5F5" BorderBrush="#F3C9C9" BorderThickness="1" CornerRadius="4">
        <StackPanel>
          <CheckBox x:Name="AlsoHome" FontWeight="SemiBold" Content="Also delete my workbench home"/>
          <TextBlock x:Name="HomeWarning" Margin="22,4,0,0" TextWrapping="Wrap" FontSize="12" Foreground="#8A1C1C"/>
        </StackPanel>
      </Border>
      <TextBlock Margin="0,14,0,0" TextWrapping="Wrap" FontSize="12" Foreground="#8E8E97" Text="Left alone: Node.js, Git, the GitHub CLI, the Azure CLI, the Claude CLI and your sign-ins - they are shared with everything else on this PC."/>
    </StackPanel>
    <StackPanel x:Name="Progress" Margin="24,20,24,16" Visibility="Collapsed">
      <TextBlock x:Name="Status" FontSize="16" FontWeight="SemiBold" Text="Removing..."/>
      <StackPanel x:Name="Rows" Margin="0,12,0,0"/>
      <TextBlock x:Name="Summary" Margin="0,14,0,0" TextWrapping="Wrap" FontSize="12" Foreground="#5D5D66" Text=""/>
    </StackPanel>
  </DockPanel>
</Window>
'@

$RowXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Height="36">
  <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <TextBlock x:Name="Glyph" Grid.Column="0" FontSize="14" Foreground="#C9C9D1" VerticalAlignment="Center" Text="o"/>
  <TextBlock x:Name="Name" Grid.Column="1" FontSize="15" Foreground="#8E8E97" VerticalAlignment="Center"/>
  <TextBlock x:Name="Note" Grid.Column="2" FontSize="12" Foreground="#8E8E97" VerticalAlignment="Center"/>
</Grid>
'@

function New-Row {
    param([Parameter(Mandatory)][string]$Name)
    [xml]$x = $RowXaml
    $g = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $x))
    $g.FindName('Name').Text = $Name
    return $g
}

function Set-Row {
    param($Row, [ValidateSet('running', 'done', 'failed')][string]$State, [string]$Note = '')
    $bc = New-Object Windows.Media.BrushConverter
    $glyph = $Row.FindName('Glyph')
    switch ($State) {
        'running' { $glyph.Text = '>'; $glyph.Foreground = $bc.ConvertFromString('#A3119A'); $Row.FindName('Name').Foreground = $bc.ConvertFromString('#1B1B1F') }
        'done'    { $glyph.Text = [string][char]0x2713; $glyph.Foreground = $bc.ConvertFromString('#059669'); $Row.FindName('Name').Foreground = $bc.ConvertFromString('#1B1B1F') }
        'failed'  { $glyph.Text = 'X'; $glyph.Foreground = $bc.ConvertFromString('#D12F2F'); $Row.FindName('Name').Foreground = $bc.ConvertFromString('#D12F2F') }
    }
    $Row.FindName('Note').Text = $Note
}

# Everything runs on the window's own thread: each removal takes a moment at
# most, so a repaint between rows is enough and there is no second runspace.
function Update-Screen {
    param($Window)
    $Window.Dispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::Render)
}

function Invoke-Removals {
    param($Window, [bool]$IncludeHome)
    $plan = @(
        @{ Name = 'Stop the app'; Action = { Stop-App } }
        @{ Name = 'Remove the shortcuts'; Action = { Remove-Shortcuts } }
        @{ Name = 'Remove the settings'; Action = { Remove-Settings } }
        @{ Name = 'Delete the app files'; Action = { Remove-Folder -Path $InstallRoot } }
    )
    if ($IncludeHome) { $plan += @{ Name = 'Delete the workbench home'; Action = { Remove-Folder -Path $WorkbenchHome } } }

    $rowsPanel = $Window.FindName('Rows')
    $rows = foreach ($step in $plan) { $r = New-Row -Name $step.Name; [void]$rowsPanel.Children.Add($r); $r }
    Update-Screen $Window

    $failed = $false
    for ($i = 0; $i -lt $plan.Count; $i++) {
        Set-Row -Row $rows[$i] -State running
        Update-Screen $Window
        Write-Host "==> $($plan[$i].Name)..."
        try {
            $note = & $plan[$i].Action
            Set-Row -Row $rows[$i] -State done -Note ([string]$note)
            Write-Host "OK $($plan[$i].Name) ($note)"
        } catch {
            $failed = $true
            Set-Row -Row $rows[$i] -State failed -Note 'failed'
            Write-Host "X $($plan[$i].Name): $($_.Exception.Message)" -ForegroundColor Red
            $Window.FindName('Summary').Text = "Could not finish: $($_.Exception.Message) Close the app or the folder if something is still using it, then run Uninstall again - what was already removed stays removed."
            break
        }
        Update-Screen $Window
    }

    $status = $Window.FindName('Status')
    if ($failed) {
        $status.Text = 'Uninstall did not finish'
    } else {
        $status.Text = 'FMDK Agentic OS was removed'
        $kept = if ($IncludeHome) { '' } else { " Your workbench home is still at $WorkbenchHome." }
        $Window.FindName('Summary').Text = "Left alone: Node.js, Git, the GitHub CLI, the Azure CLI, the Claude CLI and your sign-ins.$kept"
    }
    $primary = $Window.FindName('Primary')
    $primary.Content = 'Close'
    $primary.IsEnabled = $true
    $primary.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#A3119A')
    $primary.BorderBrush = $primary.Background
    Update-Screen $Window
    return -not $failed
}

function Show-UninstallWindow {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
    [xml]$x = $Xaml
    $w = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $x))
    try { $mark = Get-HiveMark; $w.Icon = $mark; $w.FindName('Logo').Source = $mark } catch { }
    $w.FindName('ItemApp').Text = "- the app and Framework CLI files under $InstallRoot"
    $w.FindName('HomeWarning').Text = "$WorkbenchHome - your portfolio, cloned projects, assets and logs. Anything not pushed to a repository is lost. Off unless you tick it."
    $primary = $w.FindName('Primary')
    $secondary = $w.FindName('Secondary')
    $state = @{ Phase = 'confirm'; Ok = $false; Ran = $false }
    $secondary.Add_Click({ $w.Close() })
    $primary.Add_Click({
        if ($state.Phase -eq 'done') { $w.Close(); return }
        $state.Phase = 'done'
        $state.Ran = $true
        $primary.IsEnabled = $false
        $secondary.Visibility = 'Collapsed'
        $w.FindName('Confirm').Visibility = 'Collapsed'
        $w.FindName('Progress').Visibility = 'Visible'
        $state.Ok = Invoke-Removals -Window $w -IncludeHome ([bool]$w.FindName('AlsoHome').IsChecked)
    })
    [void]$w.ShowDialog()
    return $state
}

# ---- console fallback: the same question, typed ----

function Invoke-ConsoleUninstall {
    Write-Host ""
    Write-Host "Remove FMDK Agentic OS from this PC?" -ForegroundColor Yellow
    Write-Host "  This stops the app and removes $InstallRoot, the shortcuts, and the CLAUDE_DIR / FMDK_CLI_PATH / NUXT_* settings."
    Write-Host "  Left alone: Node.js, Git, the GitHub CLI, the Azure CLI, the Claude CLI and your sign-ins."
    $home = Read-Host "  Also delete your workbench home at $WorkbenchHome (projects, portfolio, assets - unpushed work is lost)? Type DELETE HOME to include it, or press Enter to keep it"
    $includeHome = ($home -eq 'DELETE HOME')
    $go = Read-Host "  Type UNINSTALL to continue, or press Enter to keep everything"
    if ($go -ne 'UNINSTALL') { Write-Host "Nothing was changed."; return }
    $steps = @(
        @{ Name = 'Stop the app'; Action = { Stop-App } }
        @{ Name = 'Remove the shortcuts'; Action = { Remove-Shortcuts } }
        @{ Name = 'Remove the settings'; Action = { Remove-Settings } }
        @{ Name = 'Delete the app files'; Action = { Remove-Folder -Path $InstallRoot } }
    )
    if ($includeHome) { $steps += @{ Name = 'Delete the workbench home'; Action = { Remove-Folder -Path $WorkbenchHome } } }
    foreach ($s in $steps) {
        Write-Host "==> $($s.Name)..."
        try { $note = & $s.Action; Write-Host "OK $($s.Name) ($note)" -ForegroundColor Green }
        catch { Write-Host "X $($s.Name): $($_.Exception.Message)" -ForegroundColor Red; Write-Host "Run Uninstall again once nothing is using the folder - what was removed stays removed."; return }
    }
    Write-Host ""
    Write-Host "FMDK Agentic OS was removed." -ForegroundColor Green
    if (-not $includeHome) { Write-Host "Your workbench home is still at $WorkbenchHome." }
}

# ==== MAIN ====
# No `exit`: this runs from a -NoExit shortcut, and the same script must stay
# safe under `irm | iex` (ADR-059).
try {
    Write-Host "FMDK Agentic OS uninstaller" -ForegroundColor Green
    $window = $null
    try {
        $window = Show-UninstallWindow
    } catch {
        Write-Host "  (No window on this host - $($_.Exception.Message))" -ForegroundColor DarkGray
        Invoke-ConsoleUninstall
        return
    }
    if (-not $window.Ran) { Write-Host "Nothing was changed." }
} catch {
    Write-Host ""
    Write-Host "Uninstall stopped: $($_.Exception.Message)" -ForegroundColor Red
    return
}

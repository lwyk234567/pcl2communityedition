param(
    [Parameter(Mandatory = $true)]
    [string] $InputExe,

    [Parameter(Mandatory = $true)]
    [string] $OutputExe,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string] $ExpectedInputSha256,

    [Parameter(Mandatory = $true)]
    [string] $CecilPath,

    [string] $ReportJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$expectedInputSha256 = $ExpectedInputSha256.Trim().ToUpperInvariant()
$expectedAssemblyName = 'Plain Craft Launcher 2'
$expectedAssemblyVersion = '2.99.0.0'
$brandName = 'PCL2社区版'
$windowTitle = "PCL2社区版　"
$allowedMethodKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
[void] $allowedMethodKeys.Add('PCL.FormMain::.ctor()->System.Void')
[void] $allowedMethodKeys.Add('PCL.Application::WaitingMutex(System.Windows.StartupEventArgs)->System.Void')
[void] $allowedMethodKeys.Add('PCL.PageOtherAbout::PageOtherAbout_Loaded(System.Object,System.Windows.RoutedEventArgs)->System.Void')
[void] $allowedMethodKeys.Add('PCL.Settings::.cctor()->System.Void')

$cecilPath = [System.IO.Path]::GetFullPath($CecilPath)
if (-not (Test-Path -LiteralPath $cecilPath -PathType Leaf)) {
    throw "Mono.Cecil not found: $cecilPath"
}
[void] [System.Reflection.Assembly]::LoadFrom($cecilPath)

$InputExe = [System.IO.Path]::GetFullPath($InputExe)
$OutputExe = [System.IO.Path]::GetFullPath($OutputExe)
if ($ReportJson) {
    $ReportJson = [System.IO.Path]::GetFullPath($ReportJson)
}
if (-not (Test-Path -LiteralPath $InputExe -PathType Leaf)) {
    throw "Input executable not found: $InputExe"
}
if (Test-Path -LiteralPath $OutputExe) {
    throw "Refusing to overwrite existing output: $OutputExe"
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Label)
    if (-not [object]::Equals($Expected, $Actual)) {
        throw "$Label mismatch. Expected: $Expected; actual: $Actual"
    }
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Get-Sha256File {
    param([string] $Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
}

function Get-Sha256Bytes {
    param([byte[]] $Bytes)
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Bytes))
}

function Get-AllTypes {
    param($Module)
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($type in $Module.Types) {
        $queue.Enqueue($type)
    }
    $result = [System.Collections.Generic.List[object]]::new()
    while ($queue.Count -gt 0) {
        $type = $queue.Dequeue()
        $result.Add($type)
        foreach ($nested in $type.NestedTypes) {
            $queue.Enqueue($nested)
        }
    }
    return $result
}

function Get-AllMethods {
    param($Module)
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($type in (Get-AllTypes $Module)) {
        foreach ($method in $type.Methods) {
            $result.Add($method)
        }
    }
    return $result
}

function Get-MethodKey {
    param($Method)
    $parameterTypes = @($Method.Parameters | ForEach-Object { $_.ParameterType.FullName })
    return '{0}::{1}({2})->{3}' -f $Method.DeclaringType.FullName, $Method.Name, ($parameterTypes -join ','), $Method.ReturnType.FullName
}

function Find-Type {
    param($Module, [string] $FullName)
    $matches = @(Get-AllTypes $Module | Where-Object { $_.FullName -eq $FullName })
    Assert-Equal 1 $matches.Count "type $FullName count"
    return $matches[0]
}

function Find-Method {
    param($Type, [string] $Name, [int] $ParameterCount)
    $matches = @($Type.Methods | Where-Object { $_.Name -eq $Name -and $_.Parameters.Count -eq $ParameterCount })
    Assert-Equal 1 $matches.Count "method $($Type.FullName)::$Name/$ParameterCount count"
    return $matches[0]
}

function Find-ReferencedMethod {
    param(
        $Module,
        [string] $DeclaringType,
        [string] $Name,
        [string] $ReturnType,
        [string[]] $ParameterTypes
    )
    $matches = @{}
    foreach ($method in (Get-AllMethods $Module)) {
        if (-not $method.HasBody) { continue }
        foreach ($instruction in $method.Body.Instructions) {
            if ($instruction.Operand -isnot [Mono.Cecil.MethodReference]) { continue }
            $reference = $instruction.Operand
            if ($reference.DeclaringType.FullName -ne $DeclaringType -or
                $reference.Name -ne $Name -or
                $reference.ReturnType.FullName -ne $ReturnType) { continue }
            $actualParameters = @($reference.Parameters | ForEach-Object { $_.ParameterType.FullName })
            if (($actualParameters -join "`0") -ne ($ParameterTypes -join "`0")) { continue }
            $matches[$reference.FullName] = $reference
        }
    }
    Assert-Equal 1 $matches.Count "referenced method $DeclaringType::$Name count"
    return $Module.ImportReference(@($matches.Values)[0])
}

function New-ExternalStringSetterReference {
    param(
        $Module,
        [string] $AssemblyName,
        [string] $Namespace,
        [string] $TypeName,
        [string] $MethodName
    )
    $scopes = @($Module.AssemblyReferences | Where-Object { $_.Name -eq $AssemblyName })
    Assert-Equal 1 $scopes.Count "assembly reference $AssemblyName count"
    $declaringType = [Mono.Cecil.TypeReference]::new($Namespace, $TypeName, $Module, $scopes[0], $false)
    $method = [Mono.Cecil.MethodReference]::new($MethodName, $Module.TypeSystem.Void, $declaringType)
    $method.HasThis = $true
    $method.Parameters.Add([Mono.Cecil.ParameterDefinition]::new($Module.TypeSystem.String))
    return $method
}

function Get-NormalizedInstruction {
    param($Body, $Instruction)
    $operand = $Instruction.Operand
    if ($null -eq $operand) {
        $text = ''
    } elseif ($operand -is [Mono.Cecil.Cil.Instruction]) {
        $text = '@' + $Body.Instructions.IndexOf($operand)
    } elseif ($operand -is [Mono.Cecil.Cil.Instruction[]]) {
        $text = (@($operand | ForEach-Object { '@' + $Body.Instructions.IndexOf($_) }) -join ',')
    } elseif ($operand -is [Mono.Cecil.Cil.VariableDefinition]) {
        $text = 'V' + $operand.Index
    } elseif ($operand -is [Mono.Cecil.ParameterDefinition]) {
        $text = 'P' + $operand.Index
    } elseif ($operand -is [Mono.Cecil.MemberReference]) {
        $text = $operand.FullName
    } elseif ($operand -is [System.IFormattable]) {
        $text = $operand.ToString($null, [Globalization.CultureInfo]::InvariantCulture)
    } else {
        $text = [string] $operand
    }
    return "$($Instruction.OpCode.Code)|$text"
}

function Get-MethodFingerprint {
    param($Method)
    if (-not $Method.HasBody) {
        return "NO_BODY|$($Method.Attributes)|$($Method.ImplAttributes)"
    }
    $body = $Method.Body
    $builder = [Text.StringBuilder]::new()
    $variables = @($body.Variables | ForEach-Object { $_.VariableType.FullName }) -join ','
    [void] $builder.Append($Method.Attributes).Append('|').Append($Method.ImplAttributes).Append('|').Append($body.InitLocals).Append('|').Append($variables).AppendLine()
    foreach ($instruction in $body.Instructions) {
        [void] $builder.AppendLine((Get-NormalizedInstruction $body $instruction))
    }
    foreach ($handler in $body.ExceptionHandlers) {
        $tryStart = if ($null -eq $handler.TryStart) { -1 } else { $body.Instructions.IndexOf($handler.TryStart) }
        $tryEnd = if ($null -eq $handler.TryEnd) { -1 } else { $body.Instructions.IndexOf($handler.TryEnd) }
        $handlerStart = if ($null -eq $handler.HandlerStart) { -1 } else { $body.Instructions.IndexOf($handler.HandlerStart) }
        $handlerEnd = if ($null -eq $handler.HandlerEnd) { -1 } else { $body.Instructions.IndexOf($handler.HandlerEnd) }
        $filterStart = if ($null -eq $handler.FilterStart) { -1 } else { $body.Instructions.IndexOf($handler.FilterStart) }
        $catchType = if ($null -eq $handler.CatchType) { '' } else { $handler.CatchType.FullName }
        [void] $builder.Append('EH|').Append($handler.HandlerType).Append('|').Append($tryStart).Append('|').Append($tryEnd).Append('|').Append($handlerStart).Append('|').Append($handlerEnd).Append('|').Append($filterStart).Append('|').Append($catchType).AppendLine()
    }
    return Get-Sha256Bytes ([Text.Encoding]::UTF8.GetBytes($builder.ToString()))
}

function Get-ModuleSnapshot {
    param($Module)
    $methods = @{}
    foreach ($method in (Get-AllMethods $Module)) {
        $methods[(Get-MethodKey $method)] = Get-MethodFingerprint $method
    }
    $fields = @{}
    foreach ($type in (Get-AllTypes $Module)) {
        foreach ($field in $type.Fields) {
            $constant = if ($field.HasConstant) { [string] $field.Constant } else { '<none>' }
            $initial = if ($null -ne $field.InitialValue -and $field.InitialValue.Length -gt 0) { Get-Sha256Bytes $field.InitialValue } else { '<none>' }
            $fields["$($field.DeclaringType.FullName)::$($field.Name)"] = "$($field.Attributes)|$($field.FieldType.FullName)|$constant|$initial|$($field.HasLayoutInfo):$($field.Offset)"
        }
    }
    $resources = @{}
    foreach ($resource in $Module.Resources) {
        if ($resource -is [Mono.Cecil.EmbeddedResource]) {
            $resources[$resource.Name] = "Embedded|$($resource.Attributes)|$(Get-Sha256Bytes $resource.GetResourceData())"
        } else {
            $resources[$resource.Name] = "$($resource.ResourceType)|$($resource.Attributes)|$resource"
        }
    }
    $references = @($Module.AssemblyReferences | ForEach-Object { $_.FullName } | Sort-Object)
    return [pscustomobject]@{
        AssemblyIdentity = $Module.Assembly.Name.FullName
        RuntimeVersion = $Module.RuntimeVersion
        Mvid = [string] $Module.Mvid
        EntryPoint = $Module.EntryPoint.FullName
        Methods = $methods
        Fields = $fields
        Resources = $resources
        AssemblyReferences = $references
    }
}

function Compare-Dictionaries {
    param([string] $Label, $Before, $After, [System.Collections.Generic.List[string]] $Errors)
    foreach ($key in $Before.Keys) {
        if (-not $After.ContainsKey($key)) {
            $Errors.Add("Missing $Label`: $key")
        } elseif ($Before[$key] -ne $After[$key]) {
            $Errors.Add("Changed $Label`: $key")
        }
    }
    foreach ($key in $After.Keys) {
        if (-not $Before.ContainsKey($key)) {
            $Errors.Add("Added $Label`: $key")
        }
    }
}

function Compare-Snapshots {
    param($Before, $After)
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($property in @('AssemblyIdentity', 'RuntimeVersion', 'Mvid', 'EntryPoint')) {
        if ($Before.$property -ne $After.$property) {
            $errors.Add("Changed $property`: $($Before.$property) -> $($After.$property)")
        }
    }
    $verifiedMethods = 0
    foreach ($key in $Before.Methods.Keys) {
        if ($allowedMethodKeys.Contains($key)) { continue }
        if (-not $After.Methods.ContainsKey($key)) {
            $errors.Add("Missing non-target method: $key")
        } elseif ($Before.Methods[$key] -ne $After.Methods[$key]) {
            $errors.Add("Changed non-target method: $key")
        } else {
            $verifiedMethods++
        }
    }
    foreach ($key in $After.Methods.Keys) {
        if (-not $Before.Methods.ContainsKey($key)) {
            $errors.Add("Added method: $key")
        }
    }
    Compare-Dictionaries 'field' $Before.Fields $After.Fields $errors
    Compare-Dictionaries 'resource' $Before.Resources $After.Resources $errors
    if (($Before.AssemblyReferences -join "`0") -ne ($After.AssemblyReferences -join "`0")) {
        $errors.Add('Assembly references changed.')
    }
    return [pscustomobject]@{
        Success = $errors.Count -eq 0
        Errors = @($errors)
        NonTargetMethodsVerified = $verifiedMethods
        ResourcesVerified = $Before.Resources.Count
        FieldsVerified = $Before.Fields.Count
        AssemblyReferencesVerified = $Before.AssemblyReferences.Count
    }
}

function Get-AssemblyStringAttribute {
    param($Module, [string] $FullName)
    $matches = @($Module.Assembly.CustomAttributes | Where-Object { $_.AttributeType.FullName -eq $FullName })
    Assert-Equal 1 $matches.Count "$FullName count"
    Assert-Equal 1 $matches[0].ConstructorArguments.Count "$FullName constructor argument count"
    return [string] $matches[0].ConstructorArguments[0].Value
}

function Set-AssemblyStringAttribute {
    param($Module, [string] $FullName, [string] $Value)
    $matches = @($Module.Assembly.CustomAttributes | Where-Object { $_.AttributeType.FullName -eq $FullName })
    Assert-Equal 1 $matches.Count "$FullName count"
    Assert-Equal 1 $matches[0].ConstructorArguments.Count "$FullName constructor argument count"
    $matches[0].ConstructorArguments[0] = [Mono.Cecil.CustomAttributeArgument]::new($Module.TypeSystem.String, $Value)
}

function Get-AssemblyStringAttributes {
    param($Module)
    $result = @{}
    foreach ($attribute in $Module.Assembly.CustomAttributes) {
        if ($attribute.ConstructorArguments.Count -eq 1 -and $attribute.ConstructorArguments[0].Value -is [string]) {
            $result[$attribute.AttributeType.FullName] = [string] $attribute.ConstructorArguments[0].Value
        }
    }
    return $result
}

function Assert-AttributeChanges {
    param($Before, $After)
    $allowed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    [void] $allowed.Add('System.Reflection.AssemblyTitleAttribute')
    [void] $allowed.Add('System.Reflection.AssemblyProductAttribute')
    foreach ($key in $Before.Keys) {
        Assert-True $After.ContainsKey($key) "Missing assembly attribute: $key"
        if (-not $allowed.Contains($key)) {
            Assert-Equal $Before[$key] $After[$key] "assembly attribute $key"
        }
    }
    foreach ($key in $After.Keys) {
        Assert-True $Before.ContainsKey($key) "Added assembly attribute: $key"
    }
}

function Add-After {
    param($Processor, $Target, $Instruction)
    $Processor.InsertAfter($Target, $Instruction)
    return $Instruction
}

function Count-LoadedString {
    param($Method, [string] $Value)
    return @($Method.Body.Instructions | Where-Object { $_.OpCode.Code -eq [Mono.Cecil.Cil.Code]::Ldstr -and [string] $_.Operand -ceq $Value }).Count
}

function Find-InstructionAfterString {
    param($Method, [string] $Key)
    $matches = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $Method.Body.Instructions.Count - 1; $index++) {
        $instruction = $Method.Body.Instructions[$index]
        if ($instruction.OpCode.Code -eq [Mono.Cecil.Cil.Code]::Ldstr -and [string] $instruction.Operand -ceq $Key) {
            $matches.Add($Method.Body.Instructions[$index + 1])
        }
    }
    Assert-Equal 1 $matches.Count "instruction after $Key count"
    return $matches[0]
}

function Assert-Identity {
    param($Module)
    Assert-Equal $expectedAssemblyName $Module.Assembly.Name.Name 'internal assembly name'
    Assert-Equal $expectedAssemblyVersion $Module.Assembly.Name.Version.ToString() 'assembly version'
    Assert-True ($null -ne $Module.EntryPoint) 'Assembly entry point is missing.'
}

function New-ResolverStubAssembly {
    param(
        [string] $Name,
        [hashtable] $Types
    )
    $assembly = [Mono.Cecil.AssemblyDefinition]::CreateAssembly(
        [Mono.Cecil.AssemblyNameDefinition]::new($Name, [Version] '1.0.0.0'),
        $Name,
        [Mono.Cecil.ModuleKind]::Dll)
    $assembly.MainModule.Runtime = [Mono.Cecil.TargetRuntime]::Net_4_0
    foreach ($entry in $Types.GetEnumerator()) {
        $fullName = [string] $entry.Key
        $lastDot = $fullName.LastIndexOf('.')
        $namespace = if ($lastDot -lt 0) { '' } else { $fullName.Substring(0, $lastDot) }
        $typeName = if ($lastDot -lt 0) { $fullName } else { $fullName.Substring($lastDot + 1) }
        $isEnum = [bool] $entry.Value
        $baseName = if ($isEnum) { 'Enum' } else { 'Object' }
        $baseType = [Mono.Cecil.TypeReference]::new('System', $baseName, $assembly.MainModule, $assembly.MainModule.TypeSystem.CoreLibrary, $false)
        $attributes = [Mono.Cecil.TypeAttributes]::Public -bor [Mono.Cecil.TypeAttributes]::AnsiClass
        if ($isEnum) {
            $attributes = $attributes -bor [Mono.Cecil.TypeAttributes]::Sealed
        } else {
            $attributes = $attributes -bor [Mono.Cecil.TypeAttributes]::BeforeFieldInit
        }
        $type = [Mono.Cecil.TypeDefinition]::new($namespace, $typeName, [Mono.Cecil.TypeAttributes] $attributes, $baseType)
        if ($isEnum) {
            $fieldAttributes = [Mono.Cecil.FieldAttributes]::Public -bor [Mono.Cecil.FieldAttributes]::SpecialName -bor [Mono.Cecil.FieldAttributes]::RTSpecialName
            $type.Fields.Add([Mono.Cecil.FieldDefinition]::new('value__', [Mono.Cecil.FieldAttributes] $fieldAttributes, $assembly.MainModule.TypeSystem.Int32))
        }
        $assembly.MainModule.Types.Add($type)
    }
    return $assembly
}

function Add-FrameworkResolverDirectories {
    param($Resolver)
    foreach ($directory in @(
        'C:\Windows\Microsoft.NET\Framework64\v4.0.30319',
        'C:\Windows\Microsoft.NET\Framework\v4.0.30319'
    )) {
        if (Test-Path -LiteralPath $directory) {
            $Resolver.AddSearchDirectory($directory)
        }
    }
    $gacRoot = 'C:\Windows\Microsoft.NET\assembly'
    foreach ($kind in @('GAC_MSIL', 'GAC_32', 'GAC_64')) {
        $kindRoot = Join-Path $gacRoot $kind
        if (-not (Test-Path -LiteralPath $kindRoot)) { continue }
        foreach ($assemblyDirectory in Get-ChildItem -LiteralPath $kindRoot -Directory -ErrorAction SilentlyContinue) {
            foreach ($versionDirectory in Get-ChildItem -LiteralPath $assemblyDirectory.FullName -Directory -ErrorAction SilentlyContinue) {
                $Resolver.AddSearchDirectory($versionDirectory.FullName)
            }
        }
    }
}

function Assert-PatchedModule {
    param($Module)
    Assert-Equal "$brandName 启动器" (Get-AssemblyStringAttribute $Module 'System.Reflection.AssemblyTitleAttribute') 'assembly title'
    Assert-Equal $brandName (Get-AssemblyStringAttribute $Module 'System.Reflection.AssemblyProductAttribute') 'assembly product'

    $constructor = Find-Method (Find-Type $Module 'PCL.FormMain') '.ctor' 0
    Assert-Equal 1 (Count-LoadedString $constructor $windowTitle) 'main-window title literal count'
    Assert-Equal 1 (Count-LoadedString $constructor $brandName) 'main-window logo literal count'

    $waitingMutex = Find-Method (Find-Type $Module 'PCL.Application') 'WaitingMutex' 1
    Assert-Equal 1 (Count-LoadedString $waitingMutex $windowTitle) 'single-instance title literal count'
    Assert-Equal 0 (Count-LoadedString $waitingMutex "Plain Craft Launcher　") 'old single-instance title literal count'

    $aboutLoaded = Find-Method (Find-Type $Module 'PCL.PageOtherAbout') 'PageOtherAbout_Loaded' 2
    Assert-Equal 1 (Count-LoadedString $aboutLoaded $brandName) 'about-page brand literal count'

    $settingsInitializer = Find-Method (Find-Type $Module 'PCL.Settings') '.cctor' 0
    $logoTypeDefault = Find-InstructionAfterString $settingsInitializer 'UiLogoType'
    Assert-Equal ([Mono.Cecil.Cil.Code]::Ldc_I4_2) $logoTypeDefault.OpCode.Code 'default logo type opcode'
    $logoTextDefault = Find-InstructionAfterString $settingsInitializer 'UiLogoText'
    Assert-Equal ([Mono.Cecil.Cil.Code]::Ldstr) $logoTextDefault.OpCode.Code 'default logo text opcode'
    Assert-Equal $brandName ([string] $logoTextDefault.Operand) 'default logo text'
    Assert-True (@($Module.Resources | Where-Object { $_.Name -eq 'Plain Craft Launcher 2.g.resources' }).Count -eq 1) 'WPF resource bundle is missing.'
}

function Find-BytePatternOffsets {
    param([byte[]] $Data, [byte[]] $Pattern)
    $hits = [System.Collections.Generic.List[int]]::new()
    for ($index = 0; $index -le $Data.Length - $Pattern.Length; $index++) {
        if ($Data[$index] -ne $Pattern[0]) { continue }
        $matches = $true
        for ($patternIndex = 1; $patternIndex -lt $Pattern.Length; $patternIndex++) {
            if ($Data[$index + $patternIndex] -ne $Pattern[$patternIndex]) {
                $matches = $false
                break
            }
        }
        if ($matches) {
            $hits.Add($index)
        }
    }
    return $hits
}

function Set-NativeVersionString {
    param(
        [byte[]] $Data,
        [string] $Key,
        [string] $OldValue,
        [string] $NewValue
    )
    Assert-True ($NewValue.Length -le $OldValue.Length) "Native version value exceeds fixed capacity for $Key."
    $keyBytes = [Text.Encoding]::Unicode.GetBytes($Key + [char] 0)
    $oldBytes = [Text.Encoding]::Unicode.GetBytes($OldValue + [char] 0)
    $newBytes = [Text.Encoding]::Unicode.GetBytes($NewValue + [char] 0)
    $keyHits = @(Find-BytePatternOffsets $Data $keyBytes)
    $valueHits = @(Find-BytePatternOffsets $Data $oldBytes)
    Assert-Equal 1 $valueHits.Count "native version value $OldValue count"
    $candidateKeyHits = @($keyHits | Where-Object {
        $candidateBlockStart = $_ - 6
        if ($candidateBlockStart -lt 0) { return $false }
        $candidateRelativeValueOffset = (6 + $keyBytes.Length + 3) -band (-bnot 3)
        return ($candidateBlockStart + $candidateRelativeValueOffset) -eq $valueHits[0]
    })
    Assert-Equal 1 $candidateKeyHits.Count "native version block for $Key count"

    $blockStart = $candidateKeyHits[0] - 6
    Assert-True ($blockStart -ge 0) "Invalid native version block start for $Key."
    $blockLength = [BitConverter]::ToUInt16($Data, $blockStart)
    $valueLength = [BitConverter]::ToUInt16($Data, $blockStart + 2)
    $valueType = [BitConverter]::ToUInt16($Data, $blockStart + 4)
    Assert-Equal ($OldValue.Length + 1) ([int] $valueLength) "native version value length for $Key"
    Assert-Equal 1 ([int] $valueType) "native version value type for $Key"

    $relativeValueOffset = (6 + $keyBytes.Length + 3) -band (-bnot 3)
    $valueOffset = $blockStart + $relativeValueOffset
    Assert-Equal $valueHits[0] $valueOffset "native version value offset for $Key"
    Assert-True ($valueOffset + $oldBytes.Length -le $blockStart + $blockLength) "Native version value exceeds block for $Key."

    [Array]::Clear($Data, $valueOffset, $oldBytes.Length)
    [Array]::Copy($newBytes, 0, $Data, $valueOffset, $newBytes.Length)
    [Array]::Copy([BitConverter]::GetBytes([UInt16] ($NewValue.Length + 1)), 0, $Data, $blockStart + 2, 2)
}

function Set-NativeVersionBranding {
    param([string] $Path)
    [byte[]] $data = [IO.File]::ReadAllBytes($Path)
    Set-NativeVersionString $data 'FileDescription' 'Plain Craft Launcher 启动器' "$brandName 启动器"
    Set-NativeVersionString $data 'ProductName' 'Plain Craft Launcher' $brandName
    [IO.File]::WriteAllBytes($Path, $data)

    [byte[]] $written = [IO.File]::ReadAllBytes($Path)
    Assert-Equal 1 @(Find-BytePatternOffsets $written ([Text.Encoding]::Unicode.GetBytes("$brandName 启动器" + [char] 0))).Count 'patched native FileDescription count'
    Assert-Equal 1 @(Find-BytePatternOffsets $written ([Text.Encoding]::Unicode.GetBytes($brandName + [char] 0))).Count 'patched native ProductName count'
    Assert-Equal 0 @(Find-BytePatternOffsets $written ([Text.Encoding]::Unicode.GetBytes('Plain Craft Launcher 启动器' + [char] 0))).Count 'old native FileDescription count'
    Assert-Equal 0 @(Find-BytePatternOffsets $written ([Text.Encoding]::Unicode.GetBytes('Plain Craft Launcher' + [char] 0))).Count 'old native ProductName count'
}

$inputSha256 = Get-Sha256File $InputExe
Assert-Equal $expectedInputSha256 $inputSha256 'input SHA-256'

$resolver = [Mono.Cecil.DefaultAssemblyResolver]::new()
Add-FrameworkResolverDirectories $resolver
$pclcsStub = New-ResolverStubAssembly 'PCLCS' @{
    'PCLCS.ModLoaders' = $true
}
$meloongCoreStub = New-ResolverStubAssembly 'MeloongCore' @{
    'MeloongCore.ProgressProvider' = $false
    'MeloongCore.FileChecker' = $false
    'MeloongCore.LogLevel' = $true
}
$registerAssembly = [Mono.Cecil.DefaultAssemblyResolver].GetMethod('RegisterAssembly', [Reflection.BindingFlags] 'Instance,NonPublic')
Assert-True ($null -ne $registerAssembly) 'Unable to access Mono.Cecil resolver registration.'
[void] $registerAssembly.Invoke($resolver, @($pclcsStub))
[void] $registerAssembly.Invoke($resolver, @($meloongCoreStub))

$readerParameters = [Mono.Cecil.ReaderParameters]::new()
$readerParameters.AssemblyResolver = $resolver
$readerParameters.InMemory = $true
$readerParameters.ReadingMode = [Mono.Cecil.ReadingMode]::Deferred
$readerParameters.ReadSymbols = $false
$module = [Mono.Cecil.ModuleDefinition]::ReadModule($InputExe, $readerParameters)
try {
    Assert-Identity $module
    $before = Get-ModuleSnapshot $module
    $attributesBefore = Get-AssemblyStringAttributes $module

    Set-AssemblyStringAttribute $module 'System.Reflection.AssemblyTitleAttribute' "$brandName 启动器"
    Set-AssemblyStringAttribute $module 'System.Reflection.AssemblyProductAttribute' $brandName

    $settingsInitializer = Find-Method (Find-Type $module 'PCL.Settings') '.cctor' 0
    $logoTypeDefault = Find-InstructionAfterString $settingsInitializer 'UiLogoType'
    Assert-Equal ([Mono.Cecil.Cil.Code]::Ldc_I4_1) $logoTypeDefault.OpCode.Code 'original default logo type opcode'
    $logoTypeDefault.OpCode = [Mono.Cecil.Cil.OpCodes]::Ldc_I4_2
    $logoTypeDefault.Operand = $null
    $logoTextDefault = Find-InstructionAfterString $settingsInitializer 'UiLogoText'
    Assert-Equal ([Mono.Cecil.Cil.Code]::Ldstr) $logoTextDefault.OpCode.Code 'original default logo text opcode'
    Assert-Equal '' ([string] $logoTextDefault.Operand) 'original default logo text'
    $logoTextDefault.Operand = $brandName

    $formMain = Find-Type $module 'PCL.FormMain'
    $constructor = Find-Method $formMain '.ctor' 0
    $initialize = Find-Method $formMain 'InitializeComponent' 0
    $getTitleLabel = Find-Method $formMain 'get_LabTitleLogo' 0
    $initializeCalls = @($constructor.Body.Instructions | Where-Object {
        ($_.OpCode.Code -eq [Mono.Cecil.Cil.Code]::Call -or $_.OpCode.Code -eq [Mono.Cecil.Cil.Code]::Callvirt) -and
        $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.FullName -eq $initialize.FullName
    })
    Assert-Equal 1 $initializeCalls.Count 'FormMain InitializeComponent call count'
    $windowSetTitle = New-ExternalStringSetterReference $module 'PresentationFramework' 'System.Windows' 'Window' 'set_Title'
    $textBlockSetText = New-ExternalStringSetterReference $module 'PresentationFramework' 'System.Windows.Controls' 'TextBlock' 'set_Text'
    $processor = $constructor.Body.GetILProcessor()
    $anchor = $initializeCalls[0]
    $anchor = Add-After $processor $anchor ([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $anchor = Add-After $processor $anchor ([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldstr, $windowTitle))
    $anchor = Add-After $processor $anchor ([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Call, $windowSetTitle))
    $anchor = Add-After $processor $anchor ([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $anchor = Add-After $processor $anchor ([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $getTitleLabel))
    $anchor = Add-After $processor $anchor ([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldstr, $brandName))
    [void] (Add-After $processor $anchor ([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $textBlockSetText)))

    $waitingMutex = Find-Method (Find-Type $module 'PCL.Application') 'WaitingMutex' 1
    $oldTitleInstructions = @($waitingMutex.Body.Instructions | Where-Object {
        $_.OpCode.Code -eq [Mono.Cecil.Cil.Code]::Ldstr -and [string] $_.Operand -ceq "Plain Craft Launcher　"
    })
    Assert-Equal 1 $oldTitleInstructions.Count 'single-instance current-title lookup count'
    $oldTitleInstructions[0].Operand = $windowTitle

    $aboutType = Find-Type $module 'PCL.PageOtherAbout'
    $aboutLoaded = Find-Method $aboutType 'PageOtherAbout_Loaded' 2
    $getItem = Find-Method $aboutType 'get_ItemAboutPcl' 0
    $setItemTitle = Find-Method (Find-Type $module 'PCL.MyListItem') 'set_Title' 1
    $returns = @($aboutLoaded.Body.Instructions | Where-Object { $_.OpCode.Code -eq [Mono.Cecil.Cil.Code]::Ret })
    Assert-Equal 1 $returns.Count 'PageOtherAbout_Loaded return count'
    $aboutProcessor = $aboutLoaded.Body.GetILProcessor()
    $aboutProcessor.InsertBefore($returns[0], [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $aboutProcessor.InsertBefore($returns[0], [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $getItem))
    $aboutProcessor.InsertBefore($returns[0], [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldstr, $brandName))
    $aboutProcessor.InsertBefore($returns[0], [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $setItemTitle))

    Assert-PatchedModule $module
    $outputDirectory = Split-Path -Parent $OutputExe
    [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
    $writerParameters = [Mono.Cecil.WriterParameters]::new()
    $writerParameters.WriteSymbols = $false
    $module.Write($OutputExe, $writerParameters)
} finally {
    $module.Dispose()
}

Set-NativeVersionBranding $OutputExe

$written = [Mono.Cecil.ModuleDefinition]::ReadModule($OutputExe, $readerParameters)
try {
    Assert-Identity $written
    Assert-PatchedModule $written
    $after = Get-ModuleSnapshot $written
    $comparison = Compare-Snapshots $before $after
    if (-not $comparison.Success) {
        throw "Non-whitelisted managed content changed:`n$($comparison.Errors -join "`n")"
    }
    Assert-AttributeChanges $attributesBefore (Get-AssemblyStringAttributes $written)

    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($OutputExe)
    Assert-Equal $brandName $versionInfo.ProductName 'native ProductName'
    Assert-Equal "$brandName 启动器" $versionInfo.FileDescription 'native FileDescription'
    Assert-Equal 'Plain Craft Launcher 2.exe' $versionInfo.InternalName 'native InternalName'
    Assert-Equal 'Plain Craft Launcher 2.exe' $versionInfo.OriginalFilename 'native OriginalFilename'
    Assert-Equal $expectedAssemblyVersion $versionInfo.FileVersion 'native FileVersion'
    Assert-Equal $expectedAssemblyVersion $versionInfo.ProductVersion 'native ProductVersion'

    $report = [ordered]@{
        InputPath = $InputExe
        OutputPath = $OutputExe
        InputSha256 = $inputSha256
        OutputSha256 = Get-Sha256File $OutputExe
        InputBytes = (Get-Item -LiteralPath $InputExe).Length
        OutputBytes = (Get-Item -LiteralPath $OutputExe).Length
        AssemblyName = $written.Assembly.Name.Name
        AssemblyVersion = $written.Assembly.Name.Version.ToString()
        ModuleVersionId = [string] $written.Mvid
        BrandName = $brandName
        WindowTitle = $windowTitle
        PatchedMethods = @($allowedMethodKeys | Sort-Object)
        ChangedAssemblyAttributes = @('AssemblyTitleAttribute', 'AssemblyProductAttribute')
        NativeProductName = $versionInfo.ProductName
        NativeFileDescription = $versionInfo.FileDescription
        PreservedInternalName = $versionInfo.InternalName
        PreservedOriginalFilename = $versionInfo.OriginalFilename
        NonTargetMethodsVerified = $comparison.NonTargetMethodsVerified
        ResourcesVerified = $comparison.ResourcesVerified
        FieldsVerified = $comparison.FieldsVerified
        AssemblyReferencesVerified = $comparison.AssemblyReferencesVerified
        Status = 'PASS'
    }
    $json = $report | ConvertTo-Json -Depth 5
    $json
    if ($ReportJson) {
        $reportDirectory = Split-Path -Parent $ReportJson
        [System.IO.Directory]::CreateDirectory($reportDirectory) | Out-Null
        [System.IO.File]::WriteAllText($ReportJson, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    }
} finally {
    $written.Dispose()
}

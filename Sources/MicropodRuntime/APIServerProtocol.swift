import Foundation

/// Wire constants for the `container-apiserver` XPC protocol, ported from
/// `ContainerXPC/XPC+.swift` at container 1.3.1. Raw values are the literal
/// dictionary keys on the wire — do not rename.
enum XPCRoute: String {
    case containerList
    case containerCreate
    case containerBootstrap
    case containerCreateProcess
    case containerStartProcess
    case containerWait
    case containerDelete
    case containerStop
    case containerDial
    case containerResize
    case containerKill
    case containerState
    case containerLogs
    case containerEvent
    case containerStats
    case containerDiskUsage
    case containerCopyIn
    case containerCopyOut
    case containerExport

    case pluginLoad
    case pluginGet
    case pluginRestart
    case pluginUnload
    case pluginList

    case networkCreate
    case networkDelete
    case networkList

    case volumeCreate
    case volumeDelete
    case volumeList
    case volumeInspect
    case volumeDiskUsage
    case systemDiskUsage

    case ping

    case installKernel
    case getDefaultKernel
}

enum XPCKeys: String {
    case route
    case containers
    case id
    case processIdentifier
    case containerConfig
    case containerOptions
    case runtimeData
    case port
    case exitCode
    case exitedAt
    case containerEvent
    case error
    case fd
    case logs
    case stopOptions
    case forceDelete

    case pluginName
    case plugins
    case plugin

    case archive
    case dynamicEnv

    case ping
    case appRoot
    case installRoot
    case logRoot
    case apiServerVersion
    case apiServerCommit
    case apiServerBuild
    case apiServerAppName

    case signal
    case snapshot
    case stdin
    case stdout
    case stderr
    case status
    case width
    case height
    case processConfig

    case networkId
    case networkConfig
    case networkResource
    case networkResources

    case kernel
    case kernelTarURL
    case kernelFilePath
    case systemPlatform
    case kernelForce
    case kernelDigest

    case initImage

    case volume
    case volumes
    case volumeName
    case volumeSize
    case volumeDriver
    case volumeDriverOpts
    case volumeLabels
    case volumeReadonly
    case volumeContainerId

    case statistics
    case containerSize
    case listFilters
    case diskUsageStats

    case sourcePath
    case destinationPath
    case fileMode
    case createParents

    // container-core-images service keys
    case imageReference
    case imageNewReference
    case imageDescription
    case imageDescriptions
    case ociPlatform
    case insecureFlag
    case garbageCollect
    case maxConcurrentDownloads
    case rejectedMembers
    case digest
    case digests
    case contentPath
    case imageSize
    case filesystem
}

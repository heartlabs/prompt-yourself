# iOS App

## Adding new .swift files

New files must be registered in `HeartlabsEcho.xcodeproj/project.pbxproj`. Add:

1. `PBXFileReference` entry with a unique 8-char hex UUID
2. `PBXBuildFile` entry referencing that UUID
3. The UUID in the `HeartlabsEcho` `PBXGroup` children array
4. The UUID in the `PBXSourcesBuildPhase` files array

Search for any existing file's UUID in the `.pbxproj` to see the exact pattern, then add yours right after the last entry.

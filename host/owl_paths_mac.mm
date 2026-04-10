// Copyright 2026 AntlerAI. All rights reserved.
// Bundle path overrides for OWL Host on macOS.
// Modeled after content/shell/app/paths_apple.mm.

#include "third_party/owl/host/owl_paths_mac.h"

#include "base/apple/bundle_locations.h"
#include "base/apple/foundation_util.h"
#include "base/base_paths.h"
#include "base/check.h"
#include "base/files/file_path.h"
#include "base/logging.h"
#include "base/path_service.h"
#include "base/strings/sys_string_conversions.h"
#include "content/public/common/content_paths.h"

namespace owl {

namespace {

base::FilePath GetContentsPath(bool is_subprocess) {
  base::FilePath path;
  base::PathService::Get(base::FILE_EXE, &path);

  // Use the is_subprocess flag (derived from --type= arg in argv) to
  // determine directory traversal depth. This is more robust than
  // path-based detection (e.g., checking for "/Helpers/").
  if (is_subprocess) {
    // Helper executable is at:
    //   OWL Host.app/Contents/Frameworks/
    //     OWL Host Framework.framework/Versions/A/Helpers/
    //       OWL Host Helper.app/Contents/MacOS/OWL Host Helper
    // Go up 9 levels to reach OWL Host.app/Contents/
    path = path.DirName()   // MacOS/
               .DirName()   // Contents/
               .DirName()   // OWL Host Helper.app/
               .DirName()   // Helpers/
               .DirName()   // A/
               .DirName()   // Versions/
               .DirName()   // OWL Host Framework.framework/
               .DirName()   // Frameworks/
               .DirName();  // Contents/
  } else {
    // Main app executable is at:
    //   OWL Host.app/Contents/MacOS/OWL Host
    // Go up 2 levels to reach OWL Host.app/Contents/
    path = path.DirName()   // MacOS/
               .DirName();  // Contents/
  }

  DCHECK_EQ("Contents", path.BaseName().value());
  return path;
}

}  // namespace

void OverrideOWLBundlePaths(bool is_subprocess) {
  base::FilePath contents_path = GetContentsPath(is_subprocess);

  // 1. OuterBundle: OWL Host.app
  base::apple::SetOverrideOuterBundlePath(contents_path.DirName());

  // 2. FrameworkBundle: OWL Host Framework.framework
  base::FilePath framework_path =
      contents_path.Append("Frameworks")
          .Append("OWL Host Framework.framework");
  base::apple::SetOverrideFrameworkBundlePath(framework_path);

  // 3. ChildProcessPath: base Helper App path.
  //    GetChildPath() appends suffixes like " (GPU)" to compute variants.
  //    Use the local framework_path directly (avoids global lookup roundtrip).
  base::FilePath helper_path =
      framework_path
          .Append("Helpers")
          .Append("OWL Host Helper.app")
          .Append("Contents")
          .Append("MacOS")
          .Append("OWL Host Helper");
  base::PathService::OverrideAndCreateIfNeeded(
      content::CHILD_PROCESS_EXE, helper_path, /*is_absolute=*/true,
      /*create=*/false);

  // 4. BundleID override from outer bundle.
  NSBundle* bundle = base::apple::OuterBundle();
  if (bundle.bundleIdentifier) {
    base::apple::SetBaseBundleIDOverride(
        base::SysNSStringToUTF8(bundle.bundleIdentifier));
  }

  LOG(INFO) << "[OWL] Bundle paths overridden"
            << " outer=" << contents_path.DirName().value()
            << " framework=" << framework_path.value()
            << " helper=" << helper_path.value();
}

}  // namespace owl

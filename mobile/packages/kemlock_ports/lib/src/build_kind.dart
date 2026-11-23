/// Which of the two builds this is (openspec: add-fdroid-release, design
/// decision 1): the one for the App Store and Google Play, with closed
/// libraries in it, or the one made of free software only, for F-Droid and
/// the releases page.
enum BuildKind { store, free }

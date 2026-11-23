/// The fewest characters a master password may have. Someone with a copy of
/// the phone's files guesses it offline, where only scrypt and the
/// password's own length slow them down.
const masterPasswordMinLength = 12;

/// Whether [password] is long enough to be set as a vault's master
/// password: at setup, when it is changed, for a new vault, after a
/// Recovery Kit unlock and when a vault that opened with its key gets one.
/// Every form that sets a master password asks this, so they agree.
///
/// Nothing asks it at unlock: a vault made before this rule keeps opening
/// with the password it has.
bool masterPasswordLongEnough(String password) => password.runes.length >= masterPasswordMinLength;

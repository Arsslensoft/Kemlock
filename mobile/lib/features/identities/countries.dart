/// A country the address and document pickers offer: its ISO 3166-1 alpha-2
/// code and its name in English and in French.
class Country {
  const Country(this.code, this.en, this.fr);

  final String code;
  final String en;
  final String fr;

  /// The name for [languageCode] ("fr", else English).
  String name(String languageCode) => languageCode == 'fr' ? fr : en;
}

/// The countries the pickers list. A country not here is typed, and kept as typed.
const countries = <Country>[
  Country('AL', 'Albania', 'Albanie'),
  Country('DZ', 'Algeria', 'Algérie'),
  Country('AR', 'Argentina', 'Argentine'),
  Country('AU', 'Australia', 'Australie'),
  Country('AT', 'Austria', 'Autriche'),
  Country('BE', 'Belgium', 'Belgique'),
  Country('BR', 'Brazil', 'Brésil'),
  Country('BG', 'Bulgaria', 'Bulgarie'),
  Country('CM', 'Cameroon', 'Cameroun'),
  Country('CA', 'Canada', 'Canada'),
  Country('CL', 'Chile', 'Chili'),
  Country('CN', 'China', 'Chine'),
  Country('CO', 'Colombia', 'Colombie'),
  Country('CI', 'Côte d’Ivoire', 'Côte d’Ivoire'),
  Country('HR', 'Croatia', 'Croatie'),
  Country('CZ', 'Czechia', 'Tchéquie'),
  Country('DK', 'Denmark', 'Danemark'),
  Country('EG', 'Egypt', 'Égypte'),
  Country('EE', 'Estonia', 'Estonie'),
  Country('FI', 'Finland', 'Finlande'),
  Country('FR', 'France', 'France'),
  Country('DE', 'Germany', 'Allemagne'),
  Country('GR', 'Greece', 'Grèce'),
  Country('HK', 'Hong Kong', 'Hong Kong'),
  Country('HU', 'Hungary', 'Hongrie'),
  Country('IS', 'Iceland', 'Islande'),
  Country('IN', 'India', 'Inde'),
  Country('ID', 'Indonesia', 'Indonésie'),
  Country('IE', 'Ireland', 'Irlande'),
  Country('IL', 'Israel', 'Israël'),
  Country('IT', 'Italy', 'Italie'),
  Country('JP', 'Japan', 'Japon'),
  Country('KE', 'Kenya', 'Kenya'),
  Country('LV', 'Latvia', 'Lettonie'),
  Country('LB', 'Lebanon', 'Liban'),
  Country('LT', 'Lithuania', 'Lituanie'),
  Country('LU', 'Luxembourg', 'Luxembourg'),
  Country('MY', 'Malaysia', 'Malaisie'),
  Country('MX', 'Mexico', 'Mexique'),
  Country('MA', 'Morocco', 'Maroc'),
  Country('NL', 'Netherlands', 'Pays-Bas'),
  Country('NZ', 'New Zealand', 'Nouvelle-Zélande'),
  Country('NG', 'Nigeria', 'Nigéria'),
  Country('NO', 'Norway', 'Norvège'),
  Country('PK', 'Pakistan', 'Pakistan'),
  Country('PE', 'Peru', 'Pérou'),
  Country('PH', 'Philippines', 'Philippines'),
  Country('PL', 'Poland', 'Pologne'),
  Country('PT', 'Portugal', 'Portugal'),
  Country('RO', 'Romania', 'Roumanie'),
  Country('SA', 'Saudi Arabia', 'Arabie saoudite'),
  Country('SN', 'Senegal', 'Sénégal'),
  Country('RS', 'Serbia', 'Serbie'),
  Country('SG', 'Singapore', 'Singapour'),
  Country('SK', 'Slovakia', 'Slovaquie'),
  Country('SI', 'Slovenia', 'Slovénie'),
  Country('ZA', 'South Africa', 'Afrique du Sud'),
  Country('KR', 'South Korea', 'Corée du Sud'),
  Country('ES', 'Spain', 'Espagne'),
  Country('SE', 'Sweden', 'Suède'),
  Country('CH', 'Switzerland', 'Suisse'),
  Country('TW', 'Taiwan', 'Taïwan'),
  Country('TH', 'Thailand', 'Thaïlande'),
  Country('TN', 'Tunisia', 'Tunisie'),
  Country('TR', 'Türkiye', 'Turquie'),
  Country('UA', 'Ukraine', 'Ukraine'),
  Country('AE', 'United Arab Emirates', 'Émirats arabes unis'),
  Country('GB', 'United Kingdom', 'Royaume-Uni'),
  Country('US', 'United States', 'États-Unis'),
  Country('UY', 'Uruguay', 'Uruguay'),
  Country('VN', 'Vietnam', 'Viêt Nam'),
];

String _fold(String text) => text.trim().toLowerCase();

/// The country with ISO code [code] (any case), or null.
Country? countryByCode(String? code) {
  if (code == null) return null;
  final folded = _fold(code);
  for (final country in countries) {
    if (country.code.toLowerCase() == folded) return country;
  }
  return null;
}

/// What a stored country shows as: the name of a known code in [languageCode],
/// else the text as stored.
String countryLabel(String stored, String languageCode) => countryByCode(stored)?.name(languageCode) ?? stored;

/// What a country field's [text] is stored as: the ISO code of a country it
/// names (in either language) or is the code of, else the text as typed.
String countryStored(String text) {
  final folded = _fold(text);
  if (folded.isEmpty) return '';
  for (final country in countries) {
    if (folded == country.en.toLowerCase() || folded == country.fr.toLowerCase() || folded == country.code.toLowerCase()) {
      return country.code;
    }
  }
  return text.trim();
}

/// The countries whose name in [languageCode] or English contains [query], at most [limit].
List<Country> searchCountries(String query, String languageCode, {int limit = 5}) {
  final folded = _fold(query);
  if (folded.isEmpty) return const [];
  return [
    for (final country in countries)
      if (country.name(languageCode).toLowerCase().contains(folded) || country.en.toLowerCase().contains(folded)) country,
  ].take(limit).toList();
}

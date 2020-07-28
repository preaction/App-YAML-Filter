requires "File::HomeDir" => "0";
requires "File::Spec" => "0";
requires "Getopt::Long" => "2.36";
requires "Hash::Merge::Simple" => "0";
requires "IO::Async" => "0.77";
requires "IO::Interactive" => "0";
requires "Import::Base" => "0.010";
requires "JSON::MaybeXS" => "0";
requires "List::Util" => "0";
requires "Module::Runtime" => "0";
requires "Net::Async::HTTP" => "0";
requires "Path::Tiny" => "0.072";
requires "Pod::Usage::Return" => "0";
requires "Regexp::Common" => "2013031301";
requires "SQL::Abstract" => "0";
requires "Time::Local" => "0";
requires "Time::Piece" => "0";
requires "URI" => "0";
requires "YAML::Tiny" => "0";
requires "boolean" => "0";
requires "perl" => "5.010";
recommends "DBD::SQLite" => "0";
recommends "DBI" => "0";
recommends "JSON::PP" => "0";
recommends "JSON::XS" => "0";
recommends "Text::CSV" => "0";
recommends "Text::CSV_XS" => "0";
recommends "YAML::Syck" => "0";
recommends "YAML::XS" => "0";

on 'test' => sub {
  requires "Capture::Tiny" => "0";
  requires "Dir::Self" => "0";
  requires "ExtUtils::MakeMaker" => "0";
  requires "File::Spec" => "0";
  requires "Future" => "0";
  requires "IO::Handle" => "0";
  requires "IPC::Open3" => "0";
  requires "JSON::PP" => "0";
  requires "Mock::MonkeyPatch" => "0";
  requires "Test::Deep" => "0";
  requires "Test::Differences" => "0";
  requires "Test::Exception" => "0";
  requires "Test::Lib" => "0";
  requires "Test::More" => "1.001005";
};

on 'test' => sub {
  recommends "CPAN::Meta" => "2.120900";
};

on 'configure' => sub {
  requires "ExtUtils::MakeMaker" => "0";
};

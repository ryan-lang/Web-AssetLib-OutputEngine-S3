requires 'perl', '5.018004';

requires 'Web::AssetLib','0.07';
requires 'Moo';
requires 'Kavorka';
requires 'Paws';
requires 'DateTime::Format::HTTP';

on 'test' => sub {
    requires 'Test::More', '0.98';
    requires 'Test::Compile';
};


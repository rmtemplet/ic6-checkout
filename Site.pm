package Site;

use strict;
use warnings;
#use lib "$ENV{HOME}/Interchange6/lib";
#use lib "$ENV{HOME}/Dancer-Plugin-Interchange6/lib";
#use lib "$ENV{HOME}/camp23/dancer/lib";

use Data::Dumper qw(Dumper);
use HTML::Strip;
use Time::Piece;
use Clone 'clone';
use Template::Flute;
use Scalar::Util qw(blessed);
use Mail::Mailer;
use Try::Tiny;
use Time::HiRes qw(tv_interval gettimeofday);

use Dancer ':syntax';
use Dancer::Plugin::Auth::Extensible;
use Dancer::Plugin::Cache::CHI;
use Dancer::Plugin::DBIC qw(schema resultset rset);
use Dancer::Plugin::Form;
use Dancer::Plugin::Interchange6;
use Dancer::Plugin::Interchange6::Routes;
use Dancer::Plugin::Interchange6::Routes::Cart;

use Interchange6;
use Interchange6::Schema;
use Interchange6::Cart;

use Site::Admin;
use Site::Cache;
use Site::Cart;
use Site::Checkout qw(track_order validate_order save_order process_payment finalize_order);
use Site::Database;
use Site::JSON;
use Site::User;
use Site::Util qw(local_log urlify);

our $VERSION = '0.1';

BEGIN {
  local_log('config_dump.log', to_dumper(config()));
}

#check_page_cache;

#-------------------- HOOKS

hook 'before_checkout_display' => sub {
    my $context = shift;
    $context->{checkout_error} = var 'checkout_error';
    #debug(to_dumper($context->{cart}));
    my $return = _set_ship_cost();
    $context->{cart_shipping} = $return->{cost} // 0;
    $context->{delivery_date} = $return->{delivery};

    my $cart = shop_cart();
    $context->{cart_handling} = $cart->cost('handling') // 0;
    $context->{cart_salestax} = $cart->cost('salestax') // 0;

    $context->{countries} = [
        map { { label => $_->name, value => $_->country_iso_code } }
            shop_schema->resultset('Country')->search({
                'active' => 1,
            })->all
        ];

    # It's terribly hard to make a selector out of an iterator. We're just going to bake it
    # up ourselves.
    my $selector_options = [];
    for my $addr (logged_in_user->search_related(
        'addresses',
        { type => 'shipping' }
    )->all) {
        push @$selector_options,
            { value => $addr->id,
              label => $addr->first_name . ' ' . $addr->last_name . ', ' . $addr->address . qq{...},
            };
    }
    push @$selector_options,
        { value => 'new',
          label => 'New address:',
        };
    $context->{shipping_addresses} = [ @$selector_options ];

    $selector_options = [];
    for my $addr (logged_in_user->search_related(
        'addresses',
        { type => 'billing' }
    )->all) {
        push @$selector_options,
            { value => $addr->id,
              label => $addr->first_name . ' ' . $addr->last_name . ', ' . $addr->address . qq{...},
            };
    }
    push @$selector_options,
        { value => 'new',
          label => 'New address:',
        };
    $context->{billing_addresses}    = [ @$selector_options ];
    $context->{available_shipmodes}  = [
        { label => 'Select Shipping', value => '', },
        Site::Cart::available_shipmodes(),
    ];
    $context->{selected_shipmode} = session 'shipping_estimate_method';
    #my($selected) = grep { $_->{selected} } @{ $context->{available_shipmodes} };
    #if ($selected) {
    #    $context->{shipmode} = $selected->{value};
    #}
    $context->{additional_styles}    = [
        { url => '/css/checkout.css' },
        { url => '/css/colorbox.css' },
    ];
    $context->{additional_scripts}   = [ { url => '/javascripts/checkout.js' } ];
};

hook 'login_required' => sub {
    #debug 'login_required hook: ' . request->path . ', ' . to_dumper({ request->params });
    if (grep { $_ eq request->path } qw(/cart /checkout /cart/checkout)) {
        session 'saved_add_to_cart_parameters' => { request->params() };
        #debug 'saved args set: ' . to_dumper(session('saved_add_to_cart_parameters'));
    }
};

#-------------------- ROUTES

prefix '/';

get qr{/|/index} => sub {
    my $context;
    my $hs = HTML::Strip->new;
    my $blog_post = shop_schema->resultset('LatestBlogPost')->search({}, { order_by => { -desc => 'date'}, rows => 1 })->single;

    if ($blog_post) {
        my $post_summary = $hs->parse($blog_post->body);
        my @words = split /\s+/, $post_summary;
        $post_summary = (join ' ' => @words[0..54]) . ' [...] ';

        my $post_date = Time::Piece->strptime($blog_post->date, '%Y-%m-%d %H:%M:%S');
        $post_date = ' (posted ' . $post_date->strftime("%b %d, %Y") . ') ';

        $context->{post_title} = $blog_post->title;
        $context->{post_url}   = $blog_post->url;
        $context->{post_date}  = $post_date;
        $context->{post_body}  = $post_summary;
    }

    template 'index', $context;
};

any [qw( get post )] => '/cart/checkout' => require_login sub {
    session 'shipping_estimate_method' => param('available_shipmodes');
    Dancer::Plugin::Interchange6::Routes::Cart::cart_route({ cart => { }})->();
    redirect '/checkout';
};

any [qw( get post )] => '/cart' => sub {
    if (request->path eq '/cart') {
        if (session('saved_add_to_cart_parameters')) {
            #debug('previous add-to-cart detected');
            my $args = session('saved_add_to_cart_parameters');
            session 'saved_add_to_cart_parameters' => undef;
            #debug 'saved args found: ' . to_dumper($args);
            forward request->path, { %$args }, { method => 'POST', };
        }
        else {
            #debug 'no saved args found!';
        }
    }
    Dancer::Plugin::Interchange6::Routes::Cart::cart_route({ cart => { template => 'cart' }})->();
};

post '/place_order' => require_login sub {
    my $context = shift;
    my $cart    = shop_cart();
    my $params  = params();

    # Process shipping and billing address selections. We will assume that the data in the form fields is what
    # was intended, and update the selected address item in the drop-down, if any.

    try {
        for my $this ({ id => 'billing_addresses_id', prefix => 'b_' },
                      {
                          id => 'shipping_addresses_id', prefix => '' }) {
            my $address;
            eval {
                my $method;
                if ($params->{$this->{id}} eq 'new') {
                    delete $params->{$this->{id}};
                    # Attempt to create a new entity, if at least one field had a value.
                    $address = shop_schema->resultset('Address')->new({});
                    $method = 'insert';
                }
                else {
                    # Update the existing address.
                    $address = shop_schema->resultset('Address')->find( $params->{$this->{id}} );
                    $method = 'update';
                }
                for my $column (grep { $_ ne 'addresses_id' and
                                           defined($params->{$this->{prefix} . $_}) and
                                               length($params->{$this->{prefix} . $_}) } $address->columns) {
                    $address->$column($params->{$this->{prefix} . $column});
                }
                my $val;
                my $to_be_saved = grep {
                    $_ ne 'country_iso_code' and ($val = $address->get_column($_)) and defined($val) and $val ne ''
                } $address->columns;
                if ($to_be_saved) {
                    $address->users_id(logged_in_user->users_id);
                    $address->states_id(shop_schema->resultset('State')->search({
                        state_iso_code => $params->{$this->{prefix} . 'state_iso_code'},
                    })->first->id);
                    $address->$method;
                }
                else {
                    undef $address;
                }
            };

            if (defined $address) {
                delete $params->{$this->{prefix} . $_} for $address->columns;
                $params->{$this->{id}} = $address->id;
            }
        }

        # If there was no explicit billing address, use the shipping address.
        $params->{billing_addresses_id} //= $params->{shipping_addresses_id};

        # Now expand the addresses into objects and fields for the checkout's convenience.
        my $billing_address  = shop_schema->resultset('Address')->find($params->{billing_addresses_id});
        #my $shipping_address = shop_schema->resultset('Address')->find($params->{shipping_addresses_id});

        $params->{first_name}  = $billing_address->first_name;
        $params->{last_name}   = $billing_address->last_name;
        $params->{address}     = $billing_address->address;
        $params->{phone}       = $billing_address->phone;
        $params->{city}        = $billing_address->city;
        $params->{postal_code} = $billing_address->postal_code;
        $params->{state}       = $billing_address->state->state_iso_code;
        $params->{country}     = $billing_address->country_iso_code;

        # Tweak other parameter-name mismatches here.
        $params->{shipping_method} //= delete $params->{available_shipmodes};

        my $order;
        $order = Site::Checkout->new_order($cart, $params);
        $order->track_order(file => $order->order_number);
        if (my $err = $order->validate_order()) {
            die "Order validation failure: " . join(',', %{ $err->errors }) . "\n";
        }
        if (my $err = $order->process_payment()) {
            die "Payment processing failure: " . join(',', %{ $err->errors }). "\n";
        }
        if (my $err = $order->finalize_order()) {
            die "Order finalization failure: " . join(',', %{ $err->errors }). "\n";
        }
        if (my $err = $order->send_receipt()) {
            debug $err;
            die "Receipt failure: " . join(',', %{ $err->errors }). "\n";
        }

        # All's well, empty the cart.
        shop_cart->clear_costs;
        shop_cart->clear;
        shop_cart->update;
        session order_number => $order->order->order_number;
        redirect '/receipt';
    }
    catch {
        error 'Detected error in checkout: ', $_;
        my $failure = $_;
        $failure =~ s/^.*://;
        $failure =~ s/^ *.*?,//;
        var 'checkout_error', $failure;
        forward '/checkout';
    };
    return;
};

get '/receipt' => require_login sub {
    my $context = shift;
    my $order_number = session('order_number');
    my $rs = shop_schema->resultset('Order')
        ->search(
            { order_number => $order_number },
        );
    #debug('query: ', $rs->as_query);
    die 'No order ' . $order_number unless $context->{order} = $rs->single;

    $context->{billing_shipping_different} = (
        $context->{order}->billing_addresses_id != $context->{order}->shipping_addresses_id
    );
    $context->{billing_shipping_same} = !$context->{billing_shipping_different};
    $context->{'has_' . $_} = $context->{order}->$_ != 0
        for qw(discount handling salestax shipping);
    $context->{shipping_method_desc} = Site::Cart::code_to_method($context->{order}->shipping_method);
    $context->{jsvars} = {
        conversionid => config->{google_conversion_id},
        total_cost => $context->{order}->total_cost,
    };
    $context->{not_email} = 1;
    $context->{additional_scripts} = [ ];
    $context->{additional_styles} = [ ];

    template 'receipt', $context;
};


sub _set_ship_cost {
    my $ship_cost;
    my $cart = shop_cart();
    my $return;
    if (my $zip = shift || param('shipping_estimate_zip') // session('shipping_estimate_zip')) {
        my $method = shift || param('shipping_estimate_method') // session('shipping_estimate_method');
        my $country = shift || param('country_iso_code') // 'US';
        $return = Site::Cart::calc_shipping(
            cart    => $cart,
            zip     => $zip,
            country => $country,
            method  => $method,
            shipper => param('shipper'),
        ) if $method;
        #debug 'ship_cost returned as ', to_dumper($return);
        $ship_cost = $return->{cost};
        if (defined $ship_cost) {
            session 'shipping_estimate_zip' => $zip;
            session 'shipping_estimate_method' => $method;
            #debug(sprintf 'set cart %s shipping cost to %s', $cart->id, $ship_cost);
            $cart->clear_costs;
            $cart->apply_cost(amount => $ship_cost, name => 'shipping', );
            #debug('here after apply_cost on a ' . ref($cart));
            #debug('and the shipping is ', $cart->cost('shipping'));
        }
    }
    else {
        $ship_cost = $cart->cost('shipping');
        #debug('retrieved shipping is ', to_dumper($ship_cost));
    }
    return $return;
}

shop_setup_routes;

1;

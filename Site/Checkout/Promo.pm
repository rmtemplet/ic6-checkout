package Site::Checkout::Promo;

use strict;
use warnings;

use Dancer ':syntax';
use Dancer::Plugin::Interchange6;
use Dancer::Plugin::DBIC qw(schema resultset rset);

sub validate_promo {
    my $code = shift;
    my $order = shift;
    if (my $promo = shop_schema->resultset('Promo')->search({
        code => lc($code),
        date_expires => [ -or => { '>' => \"now()" }, { '=' => undef } ],
    })->first) {
        my $discount;
        if ($promo->type eq 'fixed') {
            $discount = { amount => -$promo->amount };
        }
        elsif ($promo->type eq 'percent') {
            $discount = { amount => -($promo->amount/100.0), relative => 1 };
        }
        elsif ($promo->type eq 'freesku') {
            my @free_items = map {{ sku => $_, price => 0.0, name => 'Free item' }} split(/\s+/, $promo->product_sku);
            $order->cart->add($_) for @free_items;
            return $order->cart->errors if $order->cart->has_error;
            return;
        }
        elsif ($promo->type eq 'freeship') {
            return 'This promotion offers free shipping in the lower 48 US states only.'
                if $order->shipping_address->country_iso_code ne 'US'
                or grep { $order->shipping_address->state->state_iso_code eq $_ } qw/AK HI/;
            $discount = { amount => -($order->cart->cost('shipping')) };
        }
        #if ($discount->{amount} > $order->cart->total) {
        #    debug($discount, $order->cart->total);
        #    return "Promo code '$code' results in a negative order total";
        #}
        $order->cart->apply_cost(%$discount, name => 'discount', label => 'Discount');
        #debug $order->cart;
        return;
    }
    else {
        return "Promo code '$code' invalid or expired.";
    }
}

1;

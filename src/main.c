/*
 * Copyright (c) 2018 Intel Corporation
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/sys/printk.h>
#include <zephyr/usb/usbd.h>

#include <sample_usbd.h>

/* Keep-alive blink on the Thingy:53 green LED (led1). */
static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led1), gpios);

#define BLINK_PERIOD_MS 1000

/*
 * Follow VBUS: enable the USB device when VBUS appears and disable it when
 * VBUS goes away. Without this, a VBUS drop after boot (cable replug, a host
 * that power-cycles its port) leaves the D+ pull-up off and the device never
 * shows up again until reset.
 */
static void usbd_msg_cb(struct usbd_context *const ctx, const struct usbd_msg *msg)
{
	if (!usbd_can_detect_vbus(ctx)) {
		return;
	}

	if (msg->type == USBD_MSG_VBUS_READY) {
		if (usbd_enable(ctx)) {
			printk("Failed to enable USB\n");
		}
	}

	if (msg->type == USBD_MSG_VBUS_REMOVED) {
		if (usbd_disable(ctx)) {
			printk("Failed to disable USB\n");
		}
	}
}

int main(void)
{
	struct usbd_context *sample_usbd;
	int ret;

	if (gpio_is_ready_dt(&led)) {
		gpio_pin_configure_dt(&led, GPIO_OUTPUT_INACTIVE);
	}

	sample_usbd = sample_usbd_init_device(usbd_msg_cb);
	if (sample_usbd == NULL) {
		printk("Failed to initialize USB device");
		return -ENODEV;
	}

	/* Controllers without VBUS detection are enabled right away. */
	if (!usbd_can_detect_vbus(sample_usbd)) {
		ret = usbd_enable(sample_usbd);
		if (ret != 0) {
			printk("Failed to enable USB");
			return 0;
		}
	}

	printk("Bluetooth over USB sample\n");

	while (gpio_is_ready_dt(&led)) {
		gpio_pin_toggle_dt(&led);
		k_msleep(BLINK_PERIOD_MS / 2);
	}

	return 0;
}

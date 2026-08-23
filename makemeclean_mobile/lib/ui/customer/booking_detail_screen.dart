import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_colors.dart';
import '../../core/constants/app_config.dart';
import '../../core/utils/formatters.dart';
import '../../data/models/booking_model.dart';
import '../../data/models/reschedule_request_model.dart';
import '../../data/services/supabase_service.dart';
import 'booking_photos_screen.dart';
import 'refund_request_screen.dart';
import '../shared/custom_button.dart';
import '../shared/loading_indicator.dart';
import '../shared/status_badge.dart';

class BookingDetailScreen extends StatefulWidget {
  final String bookingId;

  const BookingDetailScreen({super.key, required this.bookingId});

  @override
  State<BookingDetailScreen> createState() => _BookingDetailScreenState();
}

class _BookingDetailScreenState extends State<BookingDetailScreen> {
  bool _isLoading = true;
  BookingModel? _booking;
  RescheduleRequestModel? _rescheduleRequest;
  bool _isCancelling = false;
  bool _isPaying = false;

  @override
  void initState() {
    super.initState();
    _loadBooking();
  }

  Future<void> _loadBooking() async {
    setState(() => _isLoading = true);
    try {
      final b = await SupabaseService.instance.getBookingById(widget.bookingId);
      final rr = await SupabaseService.instance.getLatestRescheduleRequest(
        widget.bookingId,
      );
      if (mounted) {
        setState(() {
          _booking = b;
          _rescheduleRequest = rr;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  bool _canCancel(BookingModel booking) {
    if (booking.status.toLowerCase() != 'upcoming') return false;
    final match = RegExp(r'\b\d{2}:\d{2}\b').firstMatch(booking.timeSlot);
    if (match == null) return true;
    final start = DateTime.tryParse('${booking.date}T${match.group(0)}:00');
    if (start == null) return true;
    return start.difference(DateTime.now()).inMinutes > 180;
  }

  Future<void> _handlePay() async {
    setState(() => _isPaying = true);
    try {
      final url = await SupabaseService.instance.createStripeCheckoutUrl(
        widget.bookingId,
      );
      final launched = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.inAppBrowserView,
      );
      if (!launched) {
        await launchUrl(
          Uri.parse(url),
          mode: LaunchMode.externalApplication,
        );
      }
      // When the user returns from Stripe checkout, refresh the booking state
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) {
        await _loadBooking();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppColors.statusCancelledText,
            content: Text('Payment failed to start: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isPaying = false);
    }
  }

  Future<void> _showRescheduleSheet() async {
    final booking = _booking;
    if (booking == null) return;
    final reasonController = TextEditingController();
    DateTime selectedDate = DateTime.now().add(const Duration(days: 1));
    String selectedTime = '09:00';
    bool submitting = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> submit() async {
              setSheetState(() => submitting = true);
              try {
                final request = await SupabaseService.instance
                    .requestReschedule(
                      bookingId: booking.id,
                      requestedDate: DateFormat('yyyy-MM-dd')
                          .format(selectedDate),
                      requestedTime: selectedTime,
                      reason: reasonController.text,
                    );
                if (mounted) {
                  setState(() => _rescheduleRequest = request);
                }
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(
                      backgroundColor: AppColors.statusCancelledText,
                      content: Text('Could not request reschedule: $e'),
                    ),
                  );
                }
              } finally {
                setSheetState(() => submitting = false);
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(context).viewInsets.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Request a new time',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 16),
                  InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: selectedDate,
                        firstDate: DateTime.now().add(const Duration(days: 1)),
                        lastDate: DateTime.now().add(const Duration(days: 90)),
                      );
                      if (picked != null) {
                        setSheetState(() => selectedDate = picked);
                      }
                    },
                    child: _sheetField(
                      LucideIcons.calendar,
                      Formatters.date(selectedDate),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: selectedTime,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(LucideIcons.clock),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    items: AppConfig.timeSlots
                        .map(
                          (time) =>
                              DropdownMenuItem(value: time, child: Text(time)),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setSheetState(() => selectedTime = value);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: reasonController,
                    decoration: InputDecoration(
                      hintText: 'Reason (optional)',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  CustomButton(
                    text: 'Submit Request',
                    isLoading: submitting,
                    onPressed: submit,
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    reasonController.dispose();
  }

  Future<void> _handleCancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Cancel Booking?'),
        content: const Text(
          'Are you sure you want to cancel this clean? Free cancellation is available up to 3 hours prior to the appointment.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep Booking'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.statusCancelledText,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel Clean'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() => _isCancelling = true);
      try {
        await SupabaseService.instance.cancelBooking(widget.bookingId);
        await _loadBooking();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Booking has been cancelled.')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: AppColors.statusCancelledText,
              content: Text('Error: ${e.toString()}'),
            ),
          );
        }
      } finally {
        if (mounted) setState(() => _isCancelling = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: LoadingIndicator(message: 'Loading booking details...'),
      );
    }

    if (_booking == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Booking Details')),
        body: const Center(child: Text('Booking not found')),
      );
    }

    final b = _booking!;
    final isUpcoming = b.status.toLowerCase() == 'upcoming';
    final isPaid = b.paymentStatus == 'paid';

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Booking Details'),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.share2),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Booking details copied')),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status & Service Header
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.borderLight),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      StatusBadge(status: b.status),
                      Text(
                        'Ref: #${b.id.substring(0, 8).toUpperCase()}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    b.serviceName,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    Formatters.currency(b.price),
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: AppColors.primary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Schedule & Location Card
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.borderLight),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Schedule & Address',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildDetailRow(
                    LucideIcons.calendar,
                    'Date',
                    Formatters.date(b.date),
                  ),
                  const SizedBox(height: 12),
                  _buildDetailRow(
                    LucideIcons.clock,
                    'Arrival Slot',
                    b.timeSlot,
                  ),
                  const SizedBox(height: 12),
                  _buildDetailRow(
                    LucideIcons.mapPin,
                    'Location',
                    '${b.address ?? ''}\n${b.city}, ${b.postcode ?? ''}'.trim(),
                  ),
                  if (b.notes != null && b.notes!.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _buildDetailRow(
                      LucideIcons.fileText,
                      'Instructions',
                      b.notes!,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Action Buttons
            if (isUpcoming &&
                !isPaid &&
                b.paymentStatus != 'refunded' &&
                b.paymentStatus != 'disputed') ...[
              CustomButton(
                text: 'Pay ${Formatters.currency(b.price)}',
                icon: const Icon(LucideIcons.creditCard, size: 18),
                isLoading: _isPaying,
                onPressed: _handlePay,
              ),
              const SizedBox(height: 12),
            ],

            if (b.invoiceNumber != null && b.invoiceNumber!.isNotEmpty) ...[
              CustomButton(
                text: 'Open Invoice',
                isOutlined: true,
                icon: const Icon(LucideIcons.receipt, size: 18),
                onPressed: () => launchUrl(
                  Uri.parse('${AppConfig.siteUrl}/invoice/${b.id}'),
                  mode: LaunchMode.externalApplication,
                ),
              ),
              const SizedBox(height: 12),
            ],

            if (_rescheduleRequest != null) ...[
              _buildNotice(
                icon: LucideIcons.refreshCw,
                title: 'Reschedule ${_rescheduleRequest!.status}',
                text:
                    '${Formatters.date(_rescheduleRequest!.requestedDate)} at ${_rescheduleRequest!.requestedTime}',
                color: const Color(0xFF2563EB),
              ),
              const SizedBox(height: 12),
            ] else if (isUpcoming) ...[
              CustomButton(
                text: 'Request to Reschedule',
                isOutlined: true,
                icon: const Icon(LucideIcons.refreshCw, size: 18),
                onPressed: _showRescheduleSheet,
              ),
              const SizedBox(height: 12),
            ],

            if (b.status.toLowerCase() == 'completed') ...[
              CustomButton(
                text: 'Upload Booking Photos',
                isOutlined: true,
                icon: const Icon(LucideIcons.imagePlus, size: 18),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => BookingPhotosScreen(bookingId: b.id),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
            ],

            if (isPaid &&
                (b.status.toLowerCase() == 'upcoming' ||
                    b.status.toLowerCase() == 'completed')) ...[
              CustomButton(
                text: 'Request Refund',
                isOutlined: true,
                icon: const Icon(LucideIcons.circleDollarSign, size: 18),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => RefundRequestScreen(bookingId: b.id),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
            ],

            if (isUpcoming) ...[
              if (_canCancel(b))
                CustomButton(
                  text: 'Cancel Booking',
                  isOutlined: true,
                  backgroundColor: AppColors.statusCancelledText,
                  textColor: AppColors.statusCancelledText,
                  isLoading: _isCancelling,
                  onPressed: _handleCancel,
                )
              else
                _buildNotice(
                  icon: LucideIcons.circleAlert,
                  title: 'Cancellation window closed',
                  text: 'Cancellations must be made at least 3 hours before.',
                  color: AppColors.textMuted,
                ),
              const SizedBox(height: 12),
            ],

            CustomButton(
              text: 'Need Help with this clean?',
              isOutlined: true,
              icon: const Icon(LucideIcons.messageSquare, size: 18),
              onPressed: () {
                showModalBottomSheet(
                  context: context,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(20),
                    ),
                  ),
                  builder: (ctx) => Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Contact MakeMeClean Support',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Our team is available 7 days a week from 7am to 7pm to help with your bookings.',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 20),
                        ListTile(
                          leading: const Icon(
                            LucideIcons.mail,
                            color: AppColors.primary,
                          ),
                          title: const Text('Email Support'),
                          subtitle: const Text('contact@makemeclean.co.uk'),
                          contentPadding: EdgeInsets.zero,
                        ),
                        const SizedBox(height: 10),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _sheetField(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
          const Spacer(),
          const Icon(LucideIcons.chevronDown, size: 16),
        ],
      ),
    );
  }

  Widget _buildNotice({
    required IconData icon,
    required String title,
    required String text,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: AppColors.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textMuted,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

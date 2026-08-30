import { Server } from 'socket.io';
import config from './config.js';

/**
 * Real-time pipe to the dashboard.
 *
 * Clients join a room per deviceId so a caregiver watching one wearer doesn't
 * receive every other wearer's traffic. Events:
 *   reading:new       - every accepted sample
 *   alert:triggered   - when a rule fires
 *   alert:ack         - when someone acknowledges an alert
 *   device:status     - online/offline transitions
 */

let io = null;

export function initSocket(httpServer) {
  io = new Server(httpServer, {
    cors: { origin: config.corsOrigin, methods: ['GET', 'POST'] },
  });

  io.on('connection', (socket) => {
    if (config.verbose) console.log(`[socket] client connected: ${socket.id}`);

    socket.on('subscribe', (deviceId) => {
      if (typeof deviceId !== 'string' || !deviceId) return;
      socket.join(`device:${deviceId}`);
      if (config.verbose) console.log(`[socket] ${socket.id} subscribed to ${deviceId}`);
      socket.emit('subscribed', { deviceId });
    });

    socket.on('unsubscribe', (deviceId) => {
      if (typeof deviceId === 'string' && deviceId) socket.leave(`device:${deviceId}`);
    });

    socket.on('disconnect', () => {
      if (config.verbose) console.log(`[socket] client disconnected: ${socket.id}`);
    });
  });

  return io;
}

const room = (deviceId) => `device:${deviceId}`;

export function emitReading(reading) {
  io?.to(room(reading.deviceId)).emit('reading:new', reading);
}

export function emitAlert(alert) {
  io?.to(room(alert.deviceId)).emit('alert:triggered', alert);
}

/**
 * Sent after an alert's SMS attempt resolves. The alert itself is pushed
 * immediately so the dashboard never waits on a third-party SMS API; this
 * follows a moment later carrying the delivery outcome.
 */
export function emitAlertUpdate(alert) {
  io?.to(room(alert.deviceId)).emit('alert:updated', alert);
}

export function emitAlertAck(alert) {
  io?.to(room(alert.deviceId)).emit('alert:ack', alert);
}

export function emitDeviceStatus(deviceId, status) {
  io?.to(room(deviceId)).emit('device:status', { deviceId, ...status });
}

export function getIo() {
  return io;
}

/**
 * API service for making authenticated requests to the backend
 */
import { authFetch, authHeader } from './auth';
import { API_BASE_URL } from './constants';

// Auth API
export const authApi = {
  updateCredentials: async (currentPassword, newUsername, newPassword) => {
    const response = await authFetch(`${API_BASE_URL}/api/auth/credentials`, {
      method: 'PUT',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        current_password: currentPassword,
        new_username: newUsername,
        new_password: newPassword,
      }),
    });
    return response.json();
  }
};

// System Pipelines API
export const systemPipelinesApi = {
  // Get all pipeline processes
  getAll: async () => {
    const response = await authFetch('/api/system/pipelines');
    return response.json();
  },

  // Get detailed pipeline information
  getDetailed: async () => {
    const response = await authFetch('/api/system/pipelines/detailed');
    return response.json();
  },

  // Kill a pipeline process
  kill: async (pid) => {
    const response = await authFetch(`/api/system/pipelines/${pid}/kill`, {
      method: 'POST',
    });
    return response.json();
  },
};

// System API — host view and report for Settings > System
export const systemApi = {
  // Host status: resources, DeckLink devices, UDP buffers, engine binary, service unit, routes
  status: async () => {
    const response = await authFetch('/api/system/status');
    return response.json();
  },

  // Plain-text system report, for an operator to keep or hand over
  report: async () => {
    const response = await authFetch('/api/system/report');
    return response.text();
  },

  // Schedule a privileged action. The backend hands it to the root helper, which delays it and
  // schedules a transient unit, so it can still be cancelled:
  // restart_gateway | reboot | shutdown | cancel (with the unit to stop).
  action: async (action, argument) => {
    const body = action === 'cancel' ? { unit: argument } : argument ? { version: argument } : {};
    const response = await authFetch(`/api/system/actions/${action}`, {
      method: 'POST',
      body: JSON.stringify(body),
    });
    return response.json();
  },

  // Uploaded packages, the deployed release, the updater's progress line
  updates: async () => {
    const response = await authFetch('/api/system/updates');
    return response.json();
  },

  // Deploy an uploaded version (the updater verifies, swaps and rolls back on its own)
  deploy: async (version) => {
    const response = await authFetch(`/api/system/updates/${encodeURIComponent(version)}/deploy`, {
      method: 'POST',
    });
    return response.json();
  },

  // Package upload with a progress callback. fetch() cannot report upload progress, so this one uses
  // XMLHttpRequest; the body is the file itself (application/octet-stream), which the server streams
  // straight to disk.
  uploadPackage: (file, onProgress) =>
    new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      xhr.open('POST', `${API_BASE_URL}/api/system/updates?filename=${encodeURIComponent(file.name)}`);

      const headers = authHeader();
      Object.entries(headers).forEach(([key, value]) => xhr.setRequestHeader(key, value));
      xhr.setRequestHeader('Content-Type', 'application/octet-stream');

      xhr.upload.onprogress = (event) => {
        if (event.lengthComputable && onProgress) {
          onProgress(Math.round((event.loaded / event.total) * 100));
        }
      };

      xhr.onload = () => {
        let payload = {};

        try {
          payload = JSON.parse(xhr.responseText || '{}');
        } catch {
          payload = { error: xhr.responseText };
        }

        if (xhr.status >= 200 && xhr.status < 300) {
          resolve(payload);
        } else {
          reject(new Error(payload.error || `upload failed (HTTP ${xhr.status})`));
        }
      };

      xhr.onerror = () => reject(new Error('upload failed: network error'));
      xhr.send(file);
    }),
};

// Nodes API
export const nodesApi = {
  // Get all nodes
  getAll: async () => {
    const response = await authFetch('/api/nodes');
    return response.json();
  },

  // Get a single node by ID
  getById: async (id) => {
    const response = await authFetch(`/api/nodes/${id}`);
    return response.json();
  },
};

// Events API
export const eventsApi = {
  getAll: async (params = {}) => {
    const query = new URLSearchParams(params).toString();
    const response = await authFetch(`/api/events${query ? '?' + query : ''}`);
    return response.json();
  },

  getCounts: async () => {
    const response = await authFetch('/api/events/counts');
    return response.json();
  },

  clear: async () => {
    const response = await authFetch('/api/events', { method: 'DELETE' });
    return response.json();
  },
};

// Routes API
export const routesApi = {
  // Get all routes
  getAll: async () => {
    const response = await authFetch('/api/routes');
    return response.json();
  },

  // Get a single route by ID
  getById: async (id) => {
    const response = await authFetch(`/api/routes/${id}`);
    return response.json();
  },

  // Create a new route
  create: async (routeData) => {
    const response = await authFetch('/api/routes', {
      method: 'POST',
      body: JSON.stringify({ route: routeData }),
    });
    return response.json();
  },

  // Update a route
  update: async (id, routeData) => {
    const response = await authFetch(`/api/routes/${id}`, {
      method: 'PUT',
      body: JSON.stringify({ route: routeData }),
    });
    return response.json();
  },

  // Delete a route
  delete: async (id) => {
    const response = await authFetch(`/api/routes/${id}`, {
      method: 'DELETE',
    });
    // Check if response has content before parsing as JSON
    const contentType = response.headers.get("content-type");
    if (contentType && contentType.includes("application/json")) {
      return response.json();
    }
    return { success: true };
  },

  // Start a route
  start: async (id) => {
    const response = await authFetch(`/api/routes/${id}/start`);

    // A refusal carries a reason the operator must see verbatim - "SDI being used by <route>" - so read
    // the body and throw THAT, instead of letting a generic failure reach the toast.
    if (!response.ok) {
      const body = await response.json().catch(() => ({}));
      throw new Error(body.error || `Start failed (${response.status})`);
    }

    return response.json();
  },

  // Stop a route
  stop: async (id) => {
    const response = await authFetch(`/api/routes/${id}/stop`);
    return response.json();
  },

  // Restart a route
  restart: async (id) => {
    const response = await authFetch(`/api/routes/${id}/restart`);
    return response.json();
  },

  // Get route statistics
  getStats: async (id) => {
    const response = await authFetch(`/api/routes/${id}/stats`);
    return response.json();
  },

  // Get destination statistics (per-sink stats)
  getDestinationStats: async (id) => {
    const response = await authFetch(`/api/routes/${id}/destination-stats`);
    return response.json();
  },

  // Bulk start/stop routes
  bulkAction: async (action, routeIds) => {
    const response = await authFetch('/api/routes/bulk-action', {
      method: 'POST',
      body: JSON.stringify({ action, route_ids: routeIds }),
    });
    return response.json();
  },

  // Clone a route
  clone: async (id) => {
    const response = await authFetch(`/api/routes/${id}/clone`, {
      method: 'POST',
    });
    return response.json();
  },

  // Switch failover source (primary ↔ secondary)
  switchSource: async (id, target) => {
    const response = await authFetch(`/api/routes/${id}/switch-source`, {
      method: 'POST',
      body: JSON.stringify({ target }),
    });
    return response.json();
  },

  // Fetch live thumbnail as a Blob (returns null if not yet available)
  previewBlob: async (id) => {
    const response = await authFetch(`/api/routes/${id}/preview`);
    if (!response.ok || response.status === 204) return null;
    return response.blob();
  },
};

export const backupApi = {
  export: async () => {
    const response = await authFetch('/api/backup/export');
    return response.json();
  },

  getDownloadLink: async () => {
    const response = await authFetch('/api/backup/create-download-link');
    return response.json();
  },

  getBackupDownloadLink: async () => {
    const response = await authFetch('/api/backup/create-backup-download-link');
    return response.json();
  },

  download: async () => {
    try {
      const { download_link } = await backupApi.getDownloadLink();

      window.open(`${API_BASE_URL}${download_link}`, '_blank');
      return true;
    } catch (error) {
      console.error('Error downloading backup:', error);
      throw error;
    }
  },

  downloadBackup: async () => {
    try {
      const { download_link } = await backupApi.getBackupDownloadLink();

      window.open(`${API_BASE_URL}${download_link}`, '_blank');
      return true;
    } catch (error) {
      console.error('Error downloading backup:', error);
      throw error;
    }
  },

  importRoutes: async (file) => {
    try {
      const text = await file.text();
      const response = await authFetch('/api/backup/import-routes', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: text,
      });
      return response.json();
    } catch (error) {
      console.error('Error importing routes:', error);
      throw error;
    }
  },

  restore: async (file) => {
    try {
      // Read the file as an ArrayBuffer
      const arrayBuffer = await file.arrayBuffer();

      // Convert ArrayBuffer to Blob with the correct MIME type
      const blob = new Blob([arrayBuffer], { type: 'application/octet-stream' });

      console.log('Sending file as binary data with Content-Type: application/octet-stream');
      const response = await authFetch('/api/restore', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/octet-stream',
        },
        body: blob,
      });

      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.error || 'Failed to restore backup');
      }

      return response.json();
    } catch (error) {
      console.error('Error in restore API call:', error);
      throw error;
    }
  },
};

// Destinations API
export const destinationsApi = {
  // Get all destinations for a route
  getAll: async (routeId) => {
    const response = await authFetch(`/api/routes/${routeId}/destinations`);
    return response.json();
  },

  // Get a single destination by ID
  getById: async (routeId, destId) => {
    const response = await authFetch(`/api/routes/${routeId}/destinations/${destId}`);
    return response.json();
  },

  // Create a new destination
  create: async (routeId, destData) => {
    const response = await authFetch(`/api/routes/${routeId}/destinations`, {
      method: 'POST',
      body: JSON.stringify({ destination: destData }),
    });
    return response.json();
  },

  // Update a destination
  update: async (routeId, destId, destData) => {
    const response = await authFetch(`/api/routes/${routeId}/destinations/${destId}`, {
      method: 'PUT',
      body: JSON.stringify({ destination: destData }),
    });
    return response.json();
  },

  // Delete a destination
  delete: async (routeId, destId) => {
    const response = await authFetch(`/api/routes/${routeId}/destinations/${destId}`, {
      method: 'DELETE',
    });
    // Check if response has content before parsing as JSON
    const contentType = response.headers.get("content-type");
    if (contentType && contentType.includes("application/json")) {
      return response.json();
    }
    return { success: true };
  },
};

// Network API
export const networkApi = {
  // Get all network interfaces
  getInterfaces: async () => {
    const response = await authFetch('/api/network/interfaces');
    return response.json();
  },

  // Display alias for one interface, keyed by MAC. An empty alias clears it.
  setInterfaceAlias: async (mac, alias) => {
    const response = await authFetch(`/api/network/interfaces/${encodeURIComponent(mac)}/alias`, {
      method: 'PUT',
      body: JSON.stringify({ alias }),
    });
    return response.json();
  },
};

// License API
export const licenseApi = {
  // Get current license status
  getStatus: async () => {
    const response = await authFetch('/api/license');
    return response.json();
  },

  // Activate a license key
  activate: async (key) => {
    const response = await authFetch('/api/license/activate', {
      method: 'POST',
      body: JSON.stringify({ key }),
    });
    return response.json();
  },

  // Deactivate current license
  deactivate: async () => {
    const response = await authFetch('/api/license/deactivate', {
      method: 'DELETE',
    });
    return response.json();
  },
};

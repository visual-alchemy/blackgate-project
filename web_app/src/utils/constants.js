/**
 * Application constants
 */

// API base URL - dynamically uses current hostname for network access
export const API_BASE_URL = `http://${window.location.hostname}:4000`;

// Authentication
export const AUTH_TOKEN_KEY = 'token';
export const AUTH_USER_KEY = 'user';

// Routes
export const ROUTES = {
  LOGIN: '/login',
  DASHBOARD: '/',
  ROUTES: '/routes',
  SETTINGS: '/settings',
  SYSTEM_PIPELINES: '/system/pipelines',
  SYSTEM_NODES: '/system/nodes',
}; 
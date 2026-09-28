import { useEffect, useState } from 'react';
import { licenseApi } from '../utils/api';

export function useLicense() {
  const [license, setLicense] = useState(null);
  useEffect(() => {
    let alive = true;
    const refresh = async () => {
      try {
        const response = await licenseApi.getStatus();
        if (alive) setLicense(response.data || null);
      } catch {
        if (alive) setLicense(null);
      }
    };
    refresh();
    const timer = setInterval(refresh, 5000);
    return () => { alive = false; clearInterval(timer); };
  }, []);
  return license;
}

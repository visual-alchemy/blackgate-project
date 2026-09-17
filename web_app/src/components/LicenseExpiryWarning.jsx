import { Alert, Button } from 'antd';
import { useLocation, useNavigate } from 'react-router-dom';
import { useLicense } from '../hooks/useLicense';
import { ROUTES } from '../utils/constants';
import { licenseExpiryWarning, formatExpiryDeadline } from '../utils/licenseWarning';

export default function LicenseExpiryWarning() {
  const license = useLicense();
  const warning = licenseExpiryWarning(license);
  const navigate = useNavigate();
  const location = useLocation();
  if (!warning) return null;

  return (
    <Alert
      showIcon
      type={warning.type}
      message={warning.message}
      style={{ marginBottom: 16 }}
      description={
        <>
          <div>Expires: {formatExpiryDeadline(license.expires_at)}</div>
          <div>Contact your provider to renew before this deadline. Streams stop at expiry; saved routes remain available.</div>
        </>
      }
      action={location.pathname !== ROUTES.LICENSE
        ? <Button size="small" onClick={() => navigate(ROUTES.LICENSE)}>View License</Button>
        : null}
    />
  );
}
